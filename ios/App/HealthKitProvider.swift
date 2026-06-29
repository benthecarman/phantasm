import Foundation
import HealthKit
import PhantasmKit

/// HealthKit-backed `HealthProviding` for the app-hosted `get_health_data` tool.
/// Lives in the app target (HealthKit is kept out of `PhantasmKit` so the package
/// stays host-testable); `PhantasmKit`'s `HealthTool` holds this behind the
/// `HealthProviding` protocol and does the (pure) parsing + formatting.
///
/// Read-only: it only ever requests *read* access. Each metric maps to a
/// HealthKit type + unit + aggregation; queries run concurrently and every
/// failure folds into a per-metric `HealthReading` (or a `HealthLookupError` for
/// a whole-call failure), so a denied permission or missing sample is recoverable,
/// never fatal (NFR-O6). HealthKit deliberately hides read-permission denial, so a
/// denied metric is indistinguishable from one with no recorded data — both come
/// back as `.noData`.
final class HealthKitProvider: HealthProviding, @unchecked Sendable {
    private let store = HKHealthStore()

    /// Every type the tool may read, used for a single up-front authorization
    /// request that covers all metrics.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKCategoryType(.sleepAnalysis),
        ]
        for metric in HealthMetric.allCases {
            if let spec = Self.quantitySpec(for: metric) {
                types.insert(spec.type)
            }
        }
        return types
    }

    /// Prompt for Health read access now, if the user hasn't been asked. Called
    /// when the health tool is enabled for a chat so the system sheet appears on
    /// that tap rather than on the model's first call. Best-effort; HealthKit only
    /// shows the sheet once per type regardless.
    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let read = readTypes
        Task { [store] in
            try? await store.requestAuthorization(toShare: [], read: read)
        }
    }

    func read(_ query: HealthQuery) async -> Result<[HealthMetricResult], HealthLookupError> {
        guard HKHealthStore.isHealthDataAvailable() else {
            return .failure(.unavailable)
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            return .failure(.authorizationFailed(
                "couldn't request Health access: \(error.localizedDescription)"))
        }

        // Query every requested metric concurrently, preserving request order.
        let results = await withTaskGroup(of: (Int, HealthMetricResult).self) { group in
            for (index, metric) in query.metrics.enumerated() {
                group.addTask { (index, await self.result(for: metric, query: query)) }
            }
            var collected: [(Int, HealthMetricResult)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return .success(results)
    }

    // MARK: - Per-metric dispatch

    private func result(for metric: HealthMetric, query: HealthQuery) async -> HealthMetricResult {
        let reading: HealthReading
        switch metric.kind {
        case .cumulative, .discrete, .latest:
            reading = await quantityReading(metric, query: query)
        case .sleep:
            reading = await sleepReading(query: query)
        case .workouts:
            reading = await workoutsReading(query: query)
        }
        return HealthMetricResult(metric: metric, reading: reading)
    }

    // MARK: - Quantity metrics

    /// A quantity metric's HealthKit mapping: its type, the unit to read it in
    /// (chosen so the numeric value is already in display terms), a display-unit
    /// label, the statistics options to compute, and a `scale` applied to the
    /// read value (e.g. fractions → percent).
    private struct QuantitySpec {
        let type: HKQuantityType
        let unit: HKUnit
        let displayUnit: String
        let options: HKStatisticsOptions
        var scale: Double = 1
    }

    private static func quantitySpec(for metric: HealthMetric) -> QuantitySpec? {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        switch metric {
        case .steps:
            return QuantitySpec(
                type: HKQuantityType(.stepCount), unit: .count(),
                displayUnit: "steps", options: .cumulativeSum)
        case .walkingRunningDistance:
            return QuantitySpec(
                type: HKQuantityType(.distanceWalkingRunning), unit: .meterUnit(with: .kilo),
                displayUnit: "km", options: .cumulativeSum)
        case .activeEnergy:
            return QuantitySpec(
                type: HKQuantityType(.activeEnergyBurned), unit: .kilocalorie(),
                displayUnit: "kcal", options: .cumulativeSum)
        case .exerciseMinutes:
            return QuantitySpec(
                type: HKQuantityType(.appleExerciseTime), unit: .minute(),
                displayUnit: "min", options: .cumulativeSum)
        case .heartRate:
            return QuantitySpec(
                type: HKQuantityType(.heartRate), unit: bpm, displayUnit: "bpm",
                options: [.discreteAverage, .discreteMin, .discreteMax])
        case .restingHeartRate:
            return QuantitySpec(
                type: HKQuantityType(.restingHeartRate), unit: bpm, displayUnit: "bpm",
                options: [.discreteAverage, .discreteMin, .discreteMax])
        case .heartRateVariability:
            return QuantitySpec(
                type: HKQuantityType(.heartRateVariabilitySDNN),
                unit: .secondUnit(with: .milli), displayUnit: "ms",
                options: [.discreteAverage, .discreteMin, .discreteMax])
        case .respiratoryRate:
            return QuantitySpec(
                type: HKQuantityType(.respiratoryRate),
                unit: HKUnit.count().unitDivided(by: .minute()), displayUnit: "breaths/min",
                options: [.discreteAverage, .discreteMin, .discreteMax])
        case .bloodOxygen:
            return QuantitySpec(
                type: HKQuantityType(.oxygenSaturation), unit: .percent(), displayUnit: "%",
                options: [.discreteAverage, .discreteMin, .discreteMax], scale: 100)
        case .weight:
            return QuantitySpec(
                type: HKQuantityType(.bodyMass), unit: .gramUnit(with: .kilo),
                displayUnit: "kg", options: .mostRecent)
        case .height:
            return QuantitySpec(
                type: HKQuantityType(.height), unit: .meterUnit(with: .centi),
                displayUnit: "cm", options: .mostRecent)
        case .bodyMassIndex:
            return QuantitySpec(
                type: HKQuantityType(.bodyMassIndex), unit: .count(),
                displayUnit: "", options: .mostRecent)
        case .bodyFat:
            return QuantitySpec(
                type: HKQuantityType(.bodyFatPercentage), unit: .percent(),
                displayUnit: "%", options: .mostRecent, scale: 100)
        case .sleep, .workouts:
            return nil
        }
    }

    private func quantityReading(_ metric: HealthMetric, query: HealthQuery) async -> HealthReading {
        guard let spec = Self.quantitySpec(for: metric) else { return .noData }
        let predicate = HKQuery.predicateForSamples(
            withStart: query.start, end: query.end, options: .strictStartDate)

        let statistics: HKStatistics? = await withCheckedContinuation { continuation in
            let statsQuery = HKStatisticsQuery(
                quantityType: spec.type, quantitySamplePredicate: predicate,
                options: spec.options
            ) { _, statistics, _ in
                continuation.resume(returning: statistics)
            }
            store.execute(statsQuery)
        }

        guard let statistics else { return .noData }
        func value(_ quantity: HKQuantity?) -> Double? {
            quantity.map { $0.doubleValue(for: spec.unit) * spec.scale }
        }

        switch metric.kind {
        case .cumulative:
            guard let sum = value(statistics.sumQuantity()) else { return .noData }
            return .quantity(HealthSummary(unit: spec.displayUnit, sum: sum))
        case .discrete:
            guard let average = value(statistics.averageQuantity()) else { return .noData }
            return .quantity(HealthSummary(
                unit: spec.displayUnit, average: average,
                minimum: value(statistics.minimumQuantity()),
                maximum: value(statistics.maximumQuantity())))
        case .latest:
            guard let latest = value(statistics.mostRecentQuantity()) else { return .noData }
            return .quantity(HealthSummary(
                unit: spec.displayUnit, latest: latest,
                latestDate: statistics.mostRecentQuantityDateInterval()?.start))
        case .sleep, .workouts:
            return .noData
        }
    }

    // MARK: - Sleep

    private func sleepReading(query: HealthQuery) async -> HealthReading {
        let predicate = HKQuery.predicateForSamples(
            withStart: query.start, end: query.end, options: .strictStartDate)
        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let sampleQuery = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(sampleQuery)
        }
        guard !samples.isEmpty else { return .noData }

        var summary = HealthSleepSummary()
        func add(_ keyPath: WritableKeyPath<HealthSleepSummary, TimeInterval?>, _ duration: TimeInterval) {
            summary[keyPath: keyPath] = (summary[keyPath: keyPath] ?? 0) + duration
        }
        for sample in samples {
            let duration = sample.endDate.timeIntervalSince(sample.startDate)
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .inBed:
                add(\.inBed, duration)
            case .awake:
                add(\.awake, duration)
            case .asleepDeep:
                add(\.deep, duration); add(\.asleep, duration)
            case .asleepREM:
                add(\.rem, duration); add(\.asleep, duration)
            case .asleepCore:
                add(\.core, duration); add(\.asleep, duration)
            case .asleepUnspecified:
                add(\.asleep, duration)
            default:
                break
            }
        }
        return .sleep(summary)
    }

    // MARK: - Workouts

    private func workoutsReading(query: HealthQuery) async -> HealthReading {
        let predicate = HKQuery.predicateForSamples(
            withStart: query.start, end: query.end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let workouts: [HKWorkout] = await withCheckedContinuation { continuation in
            let sampleQuery = HKSampleQuery(
                sampleType: HKObjectType.workoutType(), predicate: predicate,
                limit: 20, sortDescriptors: [sort]
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(sampleQuery)
        }
        guard !workouts.isEmpty else { return .noData }

        let mapped = workouts.map { workout in
            HealthWorkout(
                activity: Self.name(for: workout.workoutActivityType),
                start: workout.startDate,
                duration: workout.duration,
                energyKcal: Self.energyKcal(of: workout),
                distanceMeters: Self.distanceMeters(of: workout))
        }
        return .workouts(mapped)
    }

    private static func energyKcal(of workout: HKWorkout) -> Double? {
        workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    private static func distanceMeters(of workout: HKWorkout) -> Double? {
        let types: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
        ]
        for identifier in types {
            if let meters = workout.statistics(for: HKQuantityType(identifier))?
                .sumQuantity()?.doubleValue(for: .meter()) {
                return meters
            }
        }
        return nil
    }

    /// A short, human-readable name for the common workout activity types; the
    /// rest fall back to "Workout" (HealthKit has no built-in display name).
    private static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing, .stairs: return "Stairs"
        case .coreTraining: return "Core"
        case .pilates: return "Pilates"
        case .dance, .cardioDance: return "Dance"
        case .tennis: return "Tennis"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        default: return "Workout"
        }
    }
}
