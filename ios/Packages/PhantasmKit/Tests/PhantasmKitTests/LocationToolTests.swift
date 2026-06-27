import XCTest
@testable import PhantasmKit

final class LocationToolTests: XCTestCase {
    private func call(arguments: String = "{}") -> WireToolCall {
        WireToolCall(
            index: 0, id: "loc", type: "function",
            function: WireToolCall.Function(name: ToolName.location, arguments: arguments)
        )
    }

    func testFormatIncludesPlaceCoordinatesAndAccuracy() {
        let location = DeviceLocation(
            latitude: 37.3349,
            longitude: -122.009,
            horizontalAccuracy: 65,
            placeName: "Apple Park",
            locality: "Cupertino",
            administrativeArea: "California",
            postalCode: "95014",
            country: "United States"
        )
        let block = LocationTool.format(location)
        XCTAssertEqual(
            block,
            """
            Current location:
            place: Apple Park, Cupertino, California, United States
            postal_code: 95014
            latitude: 37.334900
            longitude: -122.009000
            accuracy: within 65 m
            """
        )
    }

    func testFormatCoordinatesOnlyWhenNoPlacemark() {
        let block = LocationTool.format(DeviceLocation(latitude: 51.5, longitude: -0.12))
        XCTAssertEqual(
            block,
            """
            Current location:
            latitude: 51.500000
            longitude: -0.120000
            """
        )
    }

    func testFormatDropsDuplicateConsecutiveComponents() {
        // A placeName that just repeats the locality shouldn't appear twice.
        let location = DeviceLocation(
            latitude: 1, longitude: 2,
            placeName: "Berlin", locality: "Berlin",
            administrativeArea: "Berlin", country: "Germany"
        )
        XCTAssertTrue(LocationTool.format(location).contains("place: Berlin, Germany"))
    }

    func testFormatOmitsNonPositiveAccuracy() {
        let location = DeviceLocation(latitude: 1, longitude: 2, horizontalAccuracy: -1)
        XCTAssertFalse(LocationTool.format(location).contains("accuracy"))
    }

    func testResolveSuccessFormatsLocation() async {
        let tool = LocationTool(provider: StubProvider(result: .success(
            DeviceLocation(latitude: 10, longitude: 20)
        )))
        let result = await tool.resolve(call())
        XCTAssertTrue(result.hasPrefix("Current location:"))
        XCTAssertTrue(result.contains("latitude: 10.000000"))
    }

    func testResolveFailureFoldsErrorIntoResult() async {
        let tool = LocationTool(provider: StubProvider(result: .failure(.permissionDenied)))
        let result = await tool.resolve(call())
        XCTAssertTrue(result.hasPrefix("get_current_location failed:"))
        XCTAssertTrue(result.contains("location permission"))
    }

    func testRegistryRoutesLocationOnceConfigured() {
        AppToolRegistry.configureLocation(provider: StubProvider(result: .failure(.restricted)))
        XCTAssertTrue(AppToolRegistry.specs.map(\.function.name).contains(ToolName.location))
        XCTAssertTrue(AppToolRegistry.isAutoResolved(name: ToolName.location))
        if case .auto = AppToolRegistry.match(call()) {} else {
            XCTFail("location should classify as an auto-resolved tool")
        }
    }
}

private struct StubProvider: LocationProviding {
    let result: Result<DeviceLocation, LocationLookupError>
    func currentLocation() async -> Result<DeviceLocation, LocationLookupError> { result }
}
