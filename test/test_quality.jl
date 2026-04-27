# Static analysis: Aqua (style/structure linting) + JET (inference checks).
# Both are kept lenient so day-to-day refactors don't trip them; tighten
# specific checks if you want stricter guarantees.

using Test
using SomatSIE

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(
        SomatSIE;
        ambiguities       = false,   # Base/stdlib piracy creates noise; revisit.
        unbound_args      = true,
        undefined_exports = true,
        project_extras    = true,
        stale_deps        = true,
        deps_compat       = true,
        piracies          = false,   # We extend Base.* on our own types — fine.
        persistent_tasks  = false,
    )
end

@testset "JET" begin
    using JET
    # `target_defined_modules` keeps JET from chasing Base/stdlib; we
    # only want failures originating in SomatSIE's own code.
    rep = JET.report_package(SomatSIE; target_defined_modules = true)
    @test isempty(JET.get_reports(rep))
end
