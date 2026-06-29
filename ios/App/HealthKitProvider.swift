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
            if let type = Self.categoryType(for: metric) {
                types.insert(type)
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
        case .events:
            reading = await eventReading(metric, query: query)
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
        let grams = HKUnit.gram()
        let milligrams = HKUnit.gramUnit(with: .milli)
        let micrograms = HKUnit.gramUnit(with: .micro)
        func cumulative(
            _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, displayUnit: String
        ) -> QuantitySpec {
            QuantitySpec(
                type: HKQuantityType(identifier), unit: unit,
                displayUnit: displayUnit, options: .cumulativeSum)
        }
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
        case .dietaryEnergy:
            return cumulative(.dietaryEnergyConsumed, unit: .kilocalorie(), displayUnit: "kcal")
        case .dietaryProtein:
            return cumulative(.dietaryProtein, unit: grams, displayUnit: "g")
        case .dietaryCarbohydrates:
            return cumulative(.dietaryCarbohydrates, unit: grams, displayUnit: "g")
        case .dietaryFatTotal:
            return cumulative(.dietaryFatTotal, unit: grams, displayUnit: "g")
        case .dietaryFatSaturated:
            return cumulative(.dietaryFatSaturated, unit: grams, displayUnit: "g")
        case .dietaryFatMonounsaturated:
            return cumulative(.dietaryFatMonounsaturated, unit: grams, displayUnit: "g")
        case .dietaryFatPolyunsaturated:
            return cumulative(.dietaryFatPolyunsaturated, unit: grams, displayUnit: "g")
        case .dietaryFiber:
            return cumulative(.dietaryFiber, unit: grams, displayUnit: "g")
        case .dietarySugar:
            return cumulative(.dietarySugar, unit: grams, displayUnit: "g")
        case .dietaryWater:
            return cumulative(.dietaryWater, unit: .literUnit(with: .milli), displayUnit: "mL")
        case .dietaryCaffeine:
            return cumulative(.dietaryCaffeine, unit: milligrams, displayUnit: "mg")
        case .dietarySodium:
            return cumulative(.dietarySodium, unit: milligrams, displayUnit: "mg")
        case .dietaryCholesterol:
            return cumulative(.dietaryCholesterol, unit: milligrams, displayUnit: "mg")
        case .dietaryCalcium:
            return cumulative(.dietaryCalcium, unit: milligrams, displayUnit: "mg")
        case .dietaryIron:
            return cumulative(.dietaryIron, unit: milligrams, displayUnit: "mg")
        case .dietaryPotassium:
            return cumulative(.dietaryPotassium, unit: milligrams, displayUnit: "mg")
        case .dietaryMagnesium:
            return cumulative(.dietaryMagnesium, unit: milligrams, displayUnit: "mg")
        case .dietaryZinc:
            return cumulative(.dietaryZinc, unit: milligrams, displayUnit: "mg")
        case .dietaryVitaminA:
            return cumulative(.dietaryVitaminA, unit: micrograms, displayUnit: "mcg")
        case .dietaryVitaminB6:
            return cumulative(.dietaryVitaminB6, unit: milligrams, displayUnit: "mg")
        case .dietaryVitaminB12:
            return cumulative(.dietaryVitaminB12, unit: micrograms, displayUnit: "mcg")
        case .dietaryVitaminC:
            return cumulative(.dietaryVitaminC, unit: milligrams, displayUnit: "mg")
        case .dietaryVitaminD:
            return cumulative(.dietaryVitaminD, unit: micrograms, displayUnit: "mcg")
        case .dietaryVitaminE:
            return cumulative(.dietaryVitaminE, unit: milligrams, displayUnit: "mg")
        case .dietaryVitaminK:
            return cumulative(.dietaryVitaminK, unit: micrograms, displayUnit: "mcg")
        case .dietaryThiamin:
            return cumulative(.dietaryThiamin, unit: milligrams, displayUnit: "mg")
        case .dietaryRiboflavin:
            return cumulative(.dietaryRiboflavin, unit: milligrams, displayUnit: "mg")
        case .dietaryNiacin:
            return cumulative(.dietaryNiacin, unit: milligrams, displayUnit: "mg")
        case .dietaryFolate:
            return cumulative(.dietaryFolate, unit: micrograms, displayUnit: "mcg")
        case .dietaryBiotin:
            return cumulative(.dietaryBiotin, unit: micrograms, displayUnit: "mcg")
        case .dietaryPantothenicAcid:
            return cumulative(.dietaryPantothenicAcid, unit: milligrams, displayUnit: "mg")
        case .dietaryPhosphorus:
            return cumulative(.dietaryPhosphorus, unit: milligrams, displayUnit: "mg")
        case .dietaryIodine:
            return cumulative(.dietaryIodine, unit: micrograms, displayUnit: "mcg")
        case .dietarySelenium:
            return cumulative(.dietarySelenium, unit: micrograms, displayUnit: "mcg")
        case .dietaryCopper:
            return cumulative(.dietaryCopper, unit: milligrams, displayUnit: "mg")
        case .dietaryManganese:
            return cumulative(.dietaryManganese, unit: milligrams, displayUnit: "mg")
        case .dietaryChromium:
            return cumulative(.dietaryChromium, unit: micrograms, displayUnit: "mcg")
        case .dietaryMolybdenum:
            return cumulative(.dietaryMolybdenum, unit: micrograms, displayUnit: "mcg")
        case .dietaryChloride:
            return cumulative(.dietaryChloride, unit: milligrams, displayUnit: "mg")
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
        case .basalBodyTemperature:
            return QuantitySpec(
                type: HKQuantityType(.basalBodyTemperature), unit: .degreeCelsius(),
                displayUnit: "degC", options: [.discreteAverage, .discreteMin, .discreteMax])
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
        case .sleep, .workouts, .menstrualFlow, .intermenstrualBleeding, .cervicalMucusQuality,
             .ovulationTestResult, .pregnancyTestResult, .progesteroneTestResult,
             .contraceptive, .lactation, .pregnancy, .bleedingDuringPregnancy,
             .bleedingAfterPregnancy, .infrequentMenstrualCycles, .irregularMenstrualCycles,
             .persistentIntermenstrualBleeding, .prolongedMenstrualPeriods,
             .sexualActivity:
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
            let daily = await quantityDailyBuckets(metric, spec: spec, query: query)
            return .quantity(HealthSummary(unit: spec.displayUnit, sum: sum, daily: daily))
        case .discrete:
            guard let average = value(statistics.averageQuantity()) else { return .noData }
            let daily = await quantityDailyBuckets(metric, spec: spec, query: query)
            return .quantity(HealthSummary(
                unit: spec.displayUnit, average: average,
                minimum: value(statistics.minimumQuantity()),
                maximum: value(statistics.maximumQuantity()),
                daily: daily))
        case .latest:
            guard let latest = value(statistics.mostRecentQuantity()) else { return .noData }
            let daily = await quantityDailyBuckets(metric, spec: spec, query: query)
            return .quantity(HealthSummary(
                unit: spec.displayUnit, latest: latest,
                latestDate: statistics.mostRecentQuantityDateInterval()?.start,
                daily: daily))
        case .sleep, .workouts, .events:
            return .noData
        }
    }

    private func quantityDailyBuckets(
        _ metric: HealthMetric, spec: QuantitySpec, query: HealthQuery
    ) async -> [HealthQuantityBucket] {
        guard query.granularity == .daily else { return [] }
        let predicate = HKQuery.predicateForSamples(
            withStart: query.start, end: query.end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let collectionQuery = HKStatisticsCollectionQuery(
                quantityType: spec.type,
                quantitySamplePredicate: predicate,
                options: spec.options,
                anchorDate: query.start,
                intervalComponents: DateComponents(day: 1)
            )
            collectionQuery.initialResultsHandler = { _, collection, _ in
                guard let collection else {
                    continuation.resume(returning: [])
                    return
                }
                var buckets: [HealthQuantityBucket] = []
                collection.enumerateStatistics(from: query.start, to: query.end) { statistics, _ in
                    if let bucket = Self.quantityBucket(metric, statistics: statistics, spec: spec) {
                        buckets.append(bucket)
                    }
                }
                continuation.resume(returning: buckets)
            }
            store.execute(collectionQuery)
        }
    }

    private static func quantityBucket(
        _ metric: HealthMetric, statistics: HKStatistics, spec: QuantitySpec
    ) -> HealthQuantityBucket? {
        func value(_ quantity: HKQuantity?) -> Double? {
            quantity.map { $0.doubleValue(for: spec.unit) * spec.scale }
        }
        switch metric.kind {
        case .cumulative:
            guard let sum = value(statistics.sumQuantity()) else { return nil }
            return HealthQuantityBucket(start: statistics.startDate, end: statistics.endDate, sum: sum)
        case .discrete:
            guard let average = value(statistics.averageQuantity()) else { return nil }
            return HealthQuantityBucket(
                start: statistics.startDate, end: statistics.endDate, average: average,
                minimum: value(statistics.minimumQuantity()),
                maximum: value(statistics.maximumQuantity()))
        case .latest:
            guard let latest = value(statistics.mostRecentQuantity()) else { return nil }
            return HealthQuantityBucket(
                start: statistics.startDate, end: statistics.endDate, latest: latest,
                latestDate: statistics.mostRecentQuantityDateInterval()?.start)
        case .sleep, .workouts, .events:
            return nil
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
        var daily: [Date: HealthSleepBucket] = [:]
        let calendar = Calendar.current
        func add(_ keyPath: WritableKeyPath<HealthSleepSummary, TimeInterval?>, _ duration: TimeInterval) {
            summary[keyPath: keyPath] = (summary[keyPath: keyPath] ?? 0) + duration
        }
        func add(
            _ keyPath: WritableKeyPath<HealthSleepBucket, TimeInterval?>,
            _ day: Date,
            _ duration: TimeInterval
        ) {
            var bucket = daily[day] ?? HealthSleepBucket(day: day)
            bucket[keyPath: keyPath] = (bucket[keyPath: keyPath] ?? 0) + duration
            daily[day] = bucket
        }
        for sample in samples {
            let duration = sample.endDate.timeIntervalSince(sample.startDate)
            let day = Self.sleepBucketDay(for: sample, calendar: calendar)
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .inBed:
                add(\.inBed, duration)
                add(\.inBed, day, duration)
            case .awake:
                add(\.awake, duration)
                add(\.awake, day, duration)
            case .asleepDeep:
                add(\.deep, duration); add(\.asleep, duration)
                add(\.deep, day, duration); add(\.asleep, day, duration)
            case .asleepREM:
                add(\.rem, duration); add(\.asleep, duration)
                add(\.rem, day, duration); add(\.asleep, day, duration)
            case .asleepCore:
                add(\.core, duration); add(\.asleep, duration)
                add(\.core, day, duration); add(\.asleep, day, duration)
            case .asleepUnspecified:
                add(\.asleep, duration)
                add(\.asleep, day, duration)
            default:
                break
            }
        }
        if query.granularity == .daily {
            summary.daily = daily.values.sorted { $0.day < $1.day }
        }
        return .sleep(summary)
    }

    private static func sleepBucketDay(for sample: HKCategorySample, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: sample.endDate)
        let hour = calendar.component(.hour, from: sample.endDate)
        guard hour >= 18 else { return day }
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }

    // MARK: - Event categories

    private struct CategorySpec {
        let type: HKCategoryType
        let valueLabels: [(value: Int, label: String)]
        var includesMenstrualCycleStart: Bool = false

        func label(for value: Int) -> String {
            valueLabels.first { $0.value == value }?.label ?? "value_\(value)"
        }
    }

    private static func categoryType(for metric: HealthMetric) -> HKCategoryType? {
        categorySpec(for: metric)?.type
    }

    private static func categorySpec(for metric: HealthMetric) -> CategorySpec? {
        let recorded = [(HKCategoryValue.notApplicable.rawValue, "recorded")]
        let vaginalBleeding = [
            (HKCategoryValueVaginalBleeding.unspecified.rawValue, "unspecified"),
            (HKCategoryValueVaginalBleeding.light.rawValue, "light"),
            (HKCategoryValueVaginalBleeding.medium.rawValue, "medium"),
            (HKCategoryValueVaginalBleeding.heavy.rawValue, "heavy"),
            (HKCategoryValueVaginalBleeding.none.rawValue, "none"),
        ]
        let pregnancyTest = [
            (HKCategoryValuePregnancyTestResult.negative.rawValue, "negative"),
            (HKCategoryValuePregnancyTestResult.positive.rawValue, "positive"),
            (HKCategoryValuePregnancyTestResult.indeterminate.rawValue, "indeterminate"),
        ]
        switch metric {
        case .menstrualFlow:
            return CategorySpec(
                type: HKCategoryType(.menstrualFlow),
                valueLabels: vaginalBleeding,
                includesMenstrualCycleStart: true)
        case .intermenstrualBleeding:
            return CategorySpec(type: HKCategoryType(.intermenstrualBleeding), valueLabels: recorded)
        case .cervicalMucusQuality:
            return CategorySpec(
                type: HKCategoryType(.cervicalMucusQuality),
                valueLabels: [
                    (HKCategoryValueCervicalMucusQuality.dry.rawValue, "dry"),
                    (HKCategoryValueCervicalMucusQuality.sticky.rawValue, "sticky"),
                    (HKCategoryValueCervicalMucusQuality.creamy.rawValue, "creamy"),
                    (HKCategoryValueCervicalMucusQuality.watery.rawValue, "watery"),
                    (HKCategoryValueCervicalMucusQuality.eggWhite.rawValue, "egg_white"),
                ])
        case .ovulationTestResult:
            return CategorySpec(
                type: HKCategoryType(.ovulationTestResult),
                valueLabels: [
                    (HKCategoryValueOvulationTestResult.negative.rawValue, "negative"),
                    (
                        HKCategoryValueOvulationTestResult.luteinizingHormoneSurge.rawValue,
                        "luteinizing_hormone_surge"
                    ),
                    (HKCategoryValueOvulationTestResult.indeterminate.rawValue, "indeterminate"),
                    (HKCategoryValueOvulationTestResult.estrogenSurge.rawValue, "estrogen_surge"),
                ])
        case .pregnancyTestResult:
            return CategorySpec(type: HKCategoryType(.pregnancyTestResult), valueLabels: pregnancyTest)
        case .progesteroneTestResult:
            return CategorySpec(
                type: HKCategoryType(.progesteroneTestResult),
                valueLabels: [
                    (HKCategoryValueProgesteroneTestResult.negative.rawValue, "negative"),
                    (HKCategoryValueProgesteroneTestResult.positive.rawValue, "positive"),
                    (HKCategoryValueProgesteroneTestResult.indeterminate.rawValue, "indeterminate"),
                ])
        case .contraceptive:
            return CategorySpec(
                type: HKCategoryType(.contraceptive),
                valueLabels: [
                    (HKCategoryValueContraceptive.unspecified.rawValue, "unspecified"),
                    (HKCategoryValueContraceptive.implant.rawValue, "implant"),
                    (HKCategoryValueContraceptive.injection.rawValue, "injection"),
                    (
                        HKCategoryValueContraceptive.intrauterineDevice.rawValue,
                        "intrauterine_device"
                    ),
                    (HKCategoryValueContraceptive.intravaginalRing.rawValue, "intravaginal_ring"),
                    (HKCategoryValueContraceptive.oral.rawValue, "oral"),
                    (HKCategoryValueContraceptive.patch.rawValue, "patch"),
                ])
        case .lactation:
            return CategorySpec(type: HKCategoryType(.lactation), valueLabels: recorded)
        case .pregnancy:
            return CategorySpec(type: HKCategoryType(.pregnancy), valueLabels: recorded)
        case .bleedingDuringPregnancy:
            return CategorySpec(
                type: HKCategoryType(.bleedingDuringPregnancy), valueLabels: vaginalBleeding)
        case .bleedingAfterPregnancy:
            return CategorySpec(
                type: HKCategoryType(.bleedingAfterPregnancy), valueLabels: vaginalBleeding)
        case .infrequentMenstrualCycles:
            return CategorySpec(
                type: HKCategoryType(.infrequentMenstrualCycles), valueLabels: recorded)
        case .irregularMenstrualCycles:
            return CategorySpec(
                type: HKCategoryType(.irregularMenstrualCycles), valueLabels: recorded)
        case .persistentIntermenstrualBleeding:
            return CategorySpec(
                type: HKCategoryType(.persistentIntermenstrualBleeding), valueLabels: recorded)
        case .prolongedMenstrualPeriods:
            return CategorySpec(
                type: HKCategoryType(.prolongedMenstrualPeriods), valueLabels: recorded)
        case .sexualActivity:
            return CategorySpec(type: HKCategoryType(.sexualActivity), valueLabels: recorded)
        default:
            return nil
        }
    }

    private func eventReading(_ metric: HealthMetric, query: HealthQuery) async -> HealthReading {
        guard let spec = Self.categorySpec(for: metric) else { return .noData }
        let predicate = HKQuery.predicateForSamples(
            withStart: query.start, end: query.end, options: .strictStartDate)
        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let sampleQuery = HKSampleQuery(
                sampleType: spec.type, predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(sampleQuery)
        }
        guard !samples.isEmpty else { return .noData }

        switch metric {
        case .sexualActivity:
            return .events(Self.sexualActivitySummary(
                samples, includeDaily: query.granularity == .daily))
        default:
            return .events(Self.categoryEventSummary(
                samples, spec: spec, includeDaily: query.granularity == .daily))
        }
    }

    private static func categoryEventSummary(
        _ samples: [HKCategorySample], spec: CategorySpec, includeDaily: Bool
    ) -> HealthEventSummary {
        var labelCounts: [String: Int] = [:]
        var dailyTotals: [Date: Int] = [:]
        var dailyLabelCounts: [Date: [String: Int]] = [:]
        let calendar = Calendar.current

        for sample in samples {
            let labels = categoryLabels(for: sample, spec: spec)
            for label in labels {
                labelCounts[label, default: 0] += 1
            }

            guard includeDaily else { continue }
            let day = calendar.startOfDay(for: sample.startDate)
            dailyTotals[day, default: 0] += 1
            var counts = dailyLabelCounts[day] ?? [:]
            for label in labels {
                counts[label, default: 0] += 1
            }
            dailyLabelCounts[day] = counts
        }

        let daily = dailyTotals.keys.sorted().map { day in
            HealthEventBucket(
                day: day,
                count: dailyTotals[day] ?? 0,
                breakdown: eventBreakdown(dailyLabelCounts[day] ?? [:], spec: spec))
        }

        return HealthEventSummary(
            count: samples.count,
            breakdown: eventBreakdown(labelCounts, spec: spec),
            daily: daily)
    }

    private static func categoryLabels(
        for sample: HKCategorySample, spec: CategorySpec
    ) -> [String] {
        var labels = [spec.label(for: sample.value)]
        if spec.includesMenstrualCycleStart,
           metadataBool(sample.metadata?[HKMetadataKeyMenstrualCycleStart]) == true {
            labels.append("cycle_start")
        }
        return labels
    }

    private static func eventBreakdown(
        _ labelCounts: [String: Int], spec: CategorySpec
    ) -> [HealthEventBreakdown] {
        var used = Set<String>()
        var breakdown: [HealthEventBreakdown] = []
        for (_, label) in spec.valueLabels {
            guard let count = labelCounts[label], count > 0 else { continue }
            breakdown.append(HealthEventBreakdown(label: label, count: count))
            used.insert(label)
        }
        for label in labelCounts.keys.sorted() where !used.contains(label) {
            if let count = labelCounts[label], count > 0 {
                breakdown.append(HealthEventBreakdown(label: label, count: count))
            }
        }
        return breakdown
    }

    private static func sexualActivitySummary(
        _ samples: [HKCategorySample], includeDaily: Bool
    ) -> HealthEventSummary {
        var protectedCount = 0
        var unprotectedCount = 0
        var unknownCount = 0
        var daily: [Date: HealthEventBucket] = [:]
        let calendar = Calendar.current

        for sample in samples {
            let protected = sexualActivityProtectionUsed(sample)
            switch protected {
            case .some(true): protectedCount += 1
            case .some(false): unprotectedCount += 1
            case .none: unknownCount += 1
            }

            guard includeDaily else { continue }
            let day = calendar.startOfDay(for: sample.startDate)
            var bucket = daily[day] ?? HealthEventBucket(
                day: day,
                count: 0,
                protectedCount: 0,
                unprotectedCount: 0,
                protectionUnknownCount: 0)
            bucket.count += 1
            switch protected {
            case .some(true):
                bucket.protectedCount = (bucket.protectedCount ?? 0) + 1
            case .some(false):
                bucket.unprotectedCount = (bucket.unprotectedCount ?? 0) + 1
            case .none:
                bucket.protectionUnknownCount = (bucket.protectionUnknownCount ?? 0) + 1
            }
            daily[day] = bucket
        }

        return HealthEventSummary(
            count: samples.count,
            protectedCount: protectedCount,
            unprotectedCount: unprotectedCount,
            protectionUnknownCount: unknownCount,
            daily: daily.values.sorted { $0.day < $1.day })
    }

    private static func sexualActivityProtectionUsed(_ sample: HKCategorySample) -> Bool? {
        metadataBool(sample.metadata?[HKMetadataKeySexualActivityProtectionUsed])
    }

    private static func metadataBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
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
