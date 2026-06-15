//
//  AIEngineTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 引擎能力分层与协商(白皮书工程补充二 / 十七)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIEngineTests {
    private let deterministic = AIEngineDescriptor(
        id: "deterministic", displayName: "Deterministic", capabilityLevel: .deterministicOnly)
    private let apple = AIEngineDescriptor(
        id: "apple", displayName: "Apple", capabilityLevel: .appleOnDevice)
    private let advanced = AIEngineDescriptor(
        id: "advanced", displayName: "Advanced", capabilityLevel: .advancedOptional)

    @Test func capabilityLevelOrdering() {
        #expect(AICapabilityLevel.none < .deterministicOnly)
        #expect(AICapabilityLevel.deterministicOnly < .appleOnDevice)
        #expect(AICapabilityLevel.appleOnDevice < .advancedOptional)
        #expect(AICapabilityLevel.allCases.count == 4)
    }

    @Test func availabilityModeFlags() {
        #expect(AIAvailabilityMode.appleModelAvailable.showsGenerativeEnhancements)
        #expect(!AIAvailabilityMode.deterministicOnly.showsGenerativeEnhancements)
        #expect(!AIAvailabilityMode.disabledByUser.showsGenerativeEnhancements)
        // surface 常驻:用户未关时恒在,关了才不显示。
        #expect(AIAvailabilityMode.deterministicOnly.showsDeterministicSurface)
        #expect(AIAvailabilityMode.appleModelAvailable.showsDeterministicSurface)
        #expect(!AIAvailabilityMode.disabledByUser.showsDeterministicSurface)
    }

    @Test func availabilityModeResolution() {
        #expect(AICapabilityNegotiator.availabilityMode(aiEnabledByUser: false, bestAvailableLevel: .appleOnDevice) == .disabledByUser)
        #expect(AICapabilityNegotiator.availabilityMode(aiEnabledByUser: true, bestAvailableLevel: .deterministicOnly) == .deterministicOnly)
        #expect(AICapabilityNegotiator.availabilityMode(aiEnabledByUser: true, bestAvailableLevel: .appleOnDevice) == .appleModelAvailable)
        #expect(AICapabilityNegotiator.availabilityMode(aiEnabledByUser: true, bestAvailableLevel: .advancedOptional) == .appleModelAvailable)
    }

    @Test func featureRequirementSatisfaction() {
        let req = AIFeatureCapabilityRequirement(
            featureID: "archiveFinder", minimumLevel: .deterministicOnly, preferredLevel: .appleOnDevice)
        #expect(req.isSatisfied(by: .deterministicOnly))
        #expect(req.isSatisfied(by: .appleOnDevice))
        #expect(!req.isSatisfied(by: .none))
    }

    @Test func resolvePicksLowestEngineMeetingPreferred() {
        // preferred = appleOnDevice,有 apple 和 advanced 时取刚好够的 apple(不过度升级)。
        let req = AIFeatureCapabilityRequirement(
            featureID: "f", minimumLevel: .deterministicOnly, preferredLevel: .appleOnDevice,
            allowsAdvancedOptionalEngine: true)
        let picked = AICapabilityNegotiator.resolve(requirement: req, from: [deterministic, apple, advanced])
        #expect(picked?.id == "apple")
    }

    @Test func resolveFallsBackToHighestWhenPreferredUnreachable() {
        // preferred = advancedOptional 但不允许它,且只有 deterministic + apple → 取最高的 apple。
        let req = AIFeatureCapabilityRequirement(
            featureID: "f", minimumLevel: .deterministicOnly, preferredLevel: .advancedOptional,
            allowsAdvancedOptionalEngine: false)
        let picked = AICapabilityNegotiator.resolve(requirement: req, from: [deterministic, apple])
        #expect(picked?.id == "apple")
    }

    @Test func resolveExcludesAdvancedWhenNotAllowed() {
        let req = AIFeatureCapabilityRequirement(
            featureID: "f", minimumLevel: .appleOnDevice, preferredLevel: .appleOnDevice,
            allowsAdvancedOptionalEngine: false)
        // 只有 advanced 引擎,但不允许 → 无合格引擎。
        #expect(AICapabilityNegotiator.resolve(requirement: req, from: [deterministic, advanced]) == nil)
    }

    @Test func resolveReturnsNilWhenNothingMeetsMinimum() {
        let req = AIFeatureCapabilityRequirement(
            featureID: "f", minimumLevel: .appleOnDevice, preferredLevel: .appleOnDevice)
        #expect(AICapabilityNegotiator.resolve(requirement: req, from: [deterministic]) == nil)
    }

    @Test func descriptorAndAvailabilityCodableRoundTrip() throws {
        let availability = AIEngineAvailability(isAvailable: true, level: .appleOnDevice, reason: nil)
        let encoded = try JSONEncoder().encode(availability)
        let decoded = try JSONDecoder().decode(AIEngineAvailability.self, from: encoded)
        #expect(decoded == availability)
        #expect(AIEngineAvailability.deterministicFallback.level == .deterministicOnly)
    }
}
