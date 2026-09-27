import Foundation
import Testing
@testable import MacWallKit

private func def(_ s: String) -> ParticleDefinition {
    ParticleDefinition(try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any])
}

private func run(_ sim: ParticleSimulation, seconds: Float) {
    for _ in 0..<Int(seconds * 60) { sim.step(1.0 / 60) }
}

@Test func emitsAtRateAndCapsAtMaxCount() {
    let d = def(#"{"maxcount":100,"emitter":[{"name":"boxrandom","rate":10}],"initializer":[{"name":"lifetimerandom","min":100,"max":100}]}"#)
    let sim = ParticleSimulation(d, seed: 1)
    run(sim, seconds: 1)
    #expect((9...11).contains(sim.particles.count))
    let capped = ParticleSimulation(def(#"{"maxcount":3,"emitter":[{"name":"boxrandom","rate":100}],"initializer":[{"name":"lifetimerandom","min":100,"max":100}]}"#), seed: 1)
    run(capped, seconds: 1)
    #expect(capped.particles.count == 3)
}

@Test func overridesScaleRateAndCount() {
    let d = def(#"{"maxcount":100,"emitter":[{"name":"boxrandom","rate":10}],"initializer":[{"name":"lifetimerandom","min":100,"max":100}]}"#)
    let sim = ParticleSimulation(d, overrides: ["rate": [2], "count": [0.1]], seed: 1)
    run(sim, seconds: 0.3)
    #expect((5...7).contains(sim.particles.count))
    run(sim, seconds: 2)
    #expect(sim.particles.count == 10)
}

@Test func particlesDieAfterLifetime() {
    let sim = ParticleSimulation(def(#"{"maxcount":100,"emitter":[{"name":"boxrandom","rate":10}],"initializer":[{"name":"lifetimerandom","min":0.5,"max":0.5}]}"#), seed: 2)
    run(sim, seconds: 2)
    #expect((4...6).contains(sim.particles.count))
}

@Test func movementAppliesGravity() {
    let sim = ParticleSimulation(def("""
    {"maxcount":1,"emitter":[{"name":"boxrandom","rate":1000,"distancemax":0}],
     "initializer":[{"name":"lifetimerandom","min":10,"max":10},{"name":"velocityrandom","min":"0 0 0","max":"0 0 0"}],
     "operator":[{"name":"movement","gravity":"0 -100 0"}]}
    """), seed: 3)
    run(sim, seconds: 1)
    let p = sim.particles[0]
    #expect(abs(p.velocity.y + 100) < 3)
    #expect(abs(p.position.y + 50) < 3)
}

@Test func alphaFadeAndSizeChange() {
    let sim = ParticleSimulation(def("""
    {"maxcount":1,"emitter":[{"name":"boxrandom","rate":1000}],
     "initializer":[{"name":"lifetimerandom","min":1,"max":1},{"name":"alpharandom","min":1,"max":1},{"name":"sizerandom","min":10,"max":10}],
     "operator":[{"name":"alphafade","fadeintime":0.5,"fadeouttime":0.5},{"name":"sizechange","startvalue":1,"endvalue":0}]}
    """), seed: 4)
    run(sim, seconds: 0.25)
    let p = sim.particles[0]
    #expect(abs(p.alpha - 0.5) < 0.05)
    #expect(abs(p.size - 7.5) < 0.3)
}

@Test func sphereEmitterRespectsRadius() {
    let sim = ParticleSimulation(def("""
    {"maxcount":200,"emitter":[{"name":"sphererandom","rate":1000,"distancemin":50,"distancemax":100,"origin":"10 20 0"}],
     "initializer":[{"name":"lifetimerandom","min":100,"max":100}]}
    """), seed: 5)
    run(sim, seconds: 0.2)
    #expect(sim.particles.count == 200)
    for p in sim.particles {
        let d = ((p.position.x - 10) * (p.position.x - 10) + (p.position.y - 20) * (p.position.y - 20)).squareRoot()
        #expect(d >= 49.9 && d <= 100.1)
        #expect(p.position.z == 0)
    }
}

@Test func reportsUnsupportedComponents() {
    let d = def(#"{"emitter":[{"name":"boxrandom"}],"operator":[{"name":"turbulence"}],"renderer":[{"name":"rope"}],"children":[{"name":"x"}]}"#)
    #expect(Set(d.unsupported) == ["operator turbulence", "renderer rope", "child systems"])
}
