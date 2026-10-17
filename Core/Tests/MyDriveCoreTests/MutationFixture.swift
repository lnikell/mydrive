import Foundation

// The standalone CLT Testing framework omits the Foundation cross-import
// overlay. Keep Foundation construction separate from the Testing source.
func mutationUUID() -> UUID { UUID() }
