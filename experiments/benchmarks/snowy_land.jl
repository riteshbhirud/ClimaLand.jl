# # Global run of land model

# The code sets up and runs ClimaLand v1, which
# includes soil, canopy, and snow, for 6 hours on a spherical domain,
# using ERA5 data as forcing. In this simulation, we have
# turned lateral flow off because horizontal boundary conditions and the
# land/sea mask are not yet supported by ClimaCore.

# This code also assesses performance, either via Nsight or by running the
# model multiple times and collecting statistics for execution time and allocations
# to make flame graphs. You can choose between the two
# by requestion --profiler nsight or --profiler flamegraph. If not provided,
# flamegraphs are created.

# When run with buildkite on clima, without Nisght, this code also compares with the previous best time
# saved at the bottom of this file

# Simulation Setup
# Number of spatial elements: 101 in horizontal, 15 in vertical
# Soil depth: 50 m
# Simulation duration: 6 hours
# Timestep: 450 s
# Timestepper: ARS111
# Fixed number of iterations: 3
# Jacobian update: every Newton iteration
# Atmos forcing update: every 3 hours
delete!(ENV, "JULIA_CUDA_MEMORY_POOL")

import SciMLBase
import ClimaComms
ClimaComms.@import_required_backends
import ClimaTimeSteppers as CTS
import ClimaCore
@show pkgversion(ClimaCore)
using ClimaUtilities.ClimaArtifacts

import ClimaUtilities.TimeVaryingInputs:
    TimeVaryingInput, LinearInterpolation, PeriodicCalendar
import ClimaUtilities.ClimaArtifacts: @clima_artifact
import ClimaParams as CP

using ClimaLand
using ClimaLand.Snow
using ClimaLand.Soil
using ClimaLand.Canopy
import ClimaLand
import ClimaLand.Parameters as LP

using Statistics
using CairoMakie
import GeoMakie
using Dates
import Profile, ProfileCanvas
using Test
using ArgParse

function parse_commandline()
    s = ArgParseSettings()
    @add_arg_table s begin
        "--profiler"
        help = "Profiler option: nsight or flamegraph"
        arg_type = String
        default = "flamegraph"
    end
    return parse_args(s)
end

const FT = Float64
time_interpolation_method = LinearInterpolation(PeriodicCalendar())
context = ClimaComms.context()
ClimaComms.init(context)
device = ClimaComms.device()
device_suffix = device isa ClimaComms.CPUSingleThreaded ? "cpu" : "gpu"
outdir = "snowy_land_benchmark_$(device_suffix)"
!ispath(outdir) && mkpath(outdir)

function setup_prob(t0, tf, Δt; outdir = outdir, nelements = (101, 15))
    earth_param_set = LP.LandParameters(FT)
    domain = ClimaLand.Domains.global_domain(FT; nelements = nelements)
    surface_space = domain.space.surface
    subsurface_space = domain.space.subsurface

    start_date = DateTime(2008)
    # Forcing data
    era5_ncdata_path = ClimaLand.Artifacts.era5_land_forcing_data2008_path(;
        context,
        lowres = true,
    )
    atmos, radiation = ClimaLand.prescribed_forcing_era5(
        era5_ncdata_path,
        surface_space,
        start_date,
        earth_param_set,
        FT;
        time_interpolation_method = time_interpolation_method,
    )

    (; ν_ss_om, ν_ss_quartz, ν_ss_gravel) =
        ClimaLand.Soil.soil_composition_parameters(subsurface_space, FT)
    (; ν, hydrology_cm, K_sat, θ_r) =
        ClimaLand.Soil.soil_vangenuchten_parameters(subsurface_space, FT)
    soil_albedo = Soil.CLMTwoBandSoilAlbedo{FT}(;
        ClimaLand.Soil.clm_soil_albedo_parameters(surface_space)...,
    )
    S_s = ClimaCore.Fields.zeros(subsurface_space) .+ FT(1e-3)
    soil_params = Soil.EnergyHydrologyParameters(
        FT;
        ν,
        ν_ss_om,
        ν_ss_quartz,
        ν_ss_gravel,
        hydrology_cm,
        K_sat,
        S_s,
        θ_r,
        albedo = soil_albedo,
    )
    f_over = FT(3.28) # 1/m
    R_sb = FT(1.484e-4 / 1000) # m/s
    runoff_model = ClimaLand.Soil.Runoff.TOPMODELRunoff{FT}(;
        f_over = f_over,
        f_max = ClimaLand.Soil.topmodel_fmax(surface_space, FT),
        R_sb = R_sb,
    )

    # Spatially varying canopy parameters from CLM
    g1 = ClimaLand.Canopy.clm_medlyn_g1(surface_space)
    rooting_depth = ClimaLand.Canopy.clm_rooting_depth(surface_space)
    (; is_c3, Vcmax25) =
        ClimaLand.Canopy.clm_photosynthesis_parameters(surface_space)
    (; Ω, G_Function, α_PAR_leaf, τ_PAR_leaf, α_NIR_leaf, τ_NIR_leaf) =
        ClimaLand.Canopy.clm_canopy_radiation_parameters(surface_space)

    # Energy Balance model
    ac_canopy = FT(2.5e3)
    # Plant Hydraulics and general plant parameters
    SAI = FT(0.0) # m2/m2
    f_root_to_shoot = FT(3.5)
    RAI = FT(1.0)
    K_sat_plant = FT(5e-9) # m/s # seems much too small?
    ψ63 = FT(-4 / 0.0098) # / MPa to m, Holtzman's original parameter value is -4 MPa
    Weibull_param = FT(4) # unitless, Holtzman's original c param value
    a = FT(0.05 * 0.0098) # Holtzman's original parameter for the bulk modulus of elasticity
    conductivity_model =
        Canopy.PlantHydraulics.Weibull{FT}(K_sat_plant, ψ63, Weibull_param)
    retention_model = Canopy.PlantHydraulics.LinearRetentionCurve{FT}(a)
    plant_ν = FT(1.44e-4)
    plant_S_s = FT(1e-2 * 0.0098) # m3/m3/MPa to m3/m3/m
    n_stem = 0
    n_leaf = 1
    h_stem = FT(0.0)
    h_leaf = FT(1.0)
    zmax = FT(0.0)
    h_canopy = h_stem + h_leaf
    compartment_midpoints =
        n_stem > 0 ? [h_stem / 2, h_stem + h_leaf / 2] : [h_leaf / 2]
    compartment_surfaces =
        n_stem > 0 ? [zmax, h_stem, h_canopy] : [zmax, h_leaf]

    z0_m = FT(0.13) * h_canopy
    z0_b = FT(0.1) * z0_m

    soil_args = (domain = domain, parameters = soil_params)
    soil_model_type = Soil.EnergyHydrology{FT}

    # Soil microbes model
    soilco2_type = Soil.Biogeochemistry.SoilCO2Model{FT}
    soilco2_ps = Soil.Biogeochemistry.SoilCO2ModelParameters(FT)
    Csom = ClimaLand.PrescribedSoilOrganicCarbon{FT}(TimeVaryingInput((t) -> 5))

    soilco2_args = (; domain = domain, parameters = soilco2_ps)

    # Now we set up the canopy model, which we set up by component:
    # Component Types
    canopy_component_types = (;
        autotrophic_respiration = Canopy.AutotrophicRespirationModel{FT},
        radiative_transfer = Canopy.TwoStreamModel{FT},
        photosynthesis = Canopy.FarquharModel{FT},
        conductance = Canopy.MedlynConductanceModel{FT},
        hydraulics = Canopy.PlantHydraulicsModel{FT},
        energy = Canopy.BigLeafEnergyModel{FT},
    )
    # Individual Component arguments
    # Set up autotrophic respiration
    autotrophic_respiration_args =
        (; parameters = Canopy.AutotrophicRespirationParameters(FT))
    # Set up radiative transfer
    radiative_transfer_args = (;
        parameters = Canopy.TwoStreamParameters(
            FT;
            Ω,
            α_PAR_leaf,
            τ_PAR_leaf,
            α_NIR_leaf,
            τ_NIR_leaf,
            G_Function,
        )
    )
    # Set up conductance
    conductance_args =
        (; parameters = Canopy.MedlynConductanceParameters(FT; g1))
    # Set up photosynthesis
    photosynthesis_args =
        (; parameters = Canopy.FarquharParameters(FT, is_c3; Vcmax25 = Vcmax25))
    # Set up plant hydraulics
    modis_lai_ncdata_path = ClimaLand.Artifacts.modis_lai_single_year_path(;
        context = nothing,
        year = Dates.year(Second(t0) + start_date),
    )
    LAIfunction = ClimaLand.prescribed_lai_modis(
        modis_lai_ncdata_path,
        surface_space,
        start_date;
        time_interpolation_method = time_interpolation_method,
    )
    ai_parameterization =
        Canopy.PrescribedSiteAreaIndex{FT}(LAIfunction, SAI, RAI)

    plant_hydraulics_ps = Canopy.PlantHydraulics.PlantHydraulicsParameters(;
        ai_parameterization = ai_parameterization,
        ν = plant_ν,
        S_s = plant_S_s,
        rooting_depth = rooting_depth,
        conductivity_model = conductivity_model,
        retention_model = retention_model,
    )
    plant_hydraulics_args = (
        parameters = plant_hydraulics_ps,
        n_stem = n_stem,
        n_leaf = n_leaf,
        compartment_midpoints = compartment_midpoints,
        compartment_surfaces = compartment_surfaces,
    )

    energy_args = (parameters = Canopy.BigLeafEnergyParameters{FT}(ac_canopy),)

    # Canopy component args
    canopy_component_args = (;
        autotrophic_respiration = autotrophic_respiration_args,
        radiative_transfer = radiative_transfer_args,
        photosynthesis = photosynthesis_args,
        conductance = conductance_args,
        hydraulics = plant_hydraulics_args,
        energy = energy_args,
    )

    # Other info needed
    shared_params = Canopy.SharedCanopyParameters{FT, typeof(earth_param_set)}(
        z0_m,
        z0_b,
        earth_param_set,
    )

    canopy_model_args = (;
        parameters = shared_params,
        domain = ClimaLand.obtain_surface_domain(domain),
    )

    # Snow model
    snow_parameters = SnowParameters{FT}(Δt; earth_param_set = earth_param_set)
    snow_args = (;
        parameters = snow_parameters,
        domain = ClimaLand.obtain_surface_domain(domain),
    )
    snow_model_type = Snow.SnowModel

    land_input = (
        atmos = atmos,
        radiation = radiation,
        runoff = runoff_model,
        soil_organic_carbon = Csom,
    )
    land = LandModel{FT}(;
        soilco2_type = soilco2_type,
        soilco2_args = soilco2_args,
        land_args = land_input,
        soil_model_type = soil_model_type,
        soil_args = soil_args,
        canopy_component_types = canopy_component_types,
        canopy_component_args = canopy_component_args,
        canopy_model_args = canopy_model_args,
        snow_args = snow_args,
        snow_model_type = snow_model_type,
    )

    Y, p, cds = initialize(land)

    @. Y.soil.ϑ_l = θ_r + (ν - θ_r) / 2
    Y.soil.θ_i .= 0
    T = FT(276.85)
    ρc_s =
        Soil.volumetric_heat_capacity.(
            Y.soil.ϑ_l,
            Y.soil.θ_i,
            soil_params.ρc_ds,
            soil_params.earth_param_set,
        )
    Y.soil.ρe_int .=
        Soil.volumetric_internal_energy.(
            Y.soil.θ_i,
            ρc_s,
            T,
            soil_params.earth_param_set,
        )
    Y.soilco2.C .= FT(0.000412) # set to atmospheric co2, mol co2 per mol air
    Y.canopy.hydraulics.ϑ_l.:1 .= plant_ν
    evaluate!(Y.canopy.energy.T, atmos.T, t0)

    Y.snow.S .= 0
    Y.snow.S_l .= 0
    Y.snow.U .= 0

    set_initial_cache! = make_set_initial_cache(land)
    exp_tendency! = make_exp_tendency(land)
    imp_tendency! = ClimaLand.make_imp_tendency(land)
    jacobian! = ClimaLand.make_jacobian(land)
    set_initial_cache!(p, Y, t0)

    # set up jacobian info
    jac_kwargs = (;
        jac_prototype = ClimaLand.FieldMatrixWithSolver(Y),
        Wfact = jacobian!,
    )

    prob = SciMLBase.ODEProblem(
        CTS.ClimaODEFunction(
            T_exp! = exp_tendency!,
            T_imp! = SciMLBase.ODEFunction(imp_tendency!; jac_kwargs...),
            dss! = ClimaLand.dss!,
        ),
        Y,
        (t0, tf),
        p,
    )

    updateat = Array(t0:(3600 * 3):tf)
    drivers = ClimaLand.get_drivers(land)
    updatefunc = ClimaLand.make_update_drivers(drivers)

    cb = ClimaLand.DriverUpdateCallback(updateat, updatefunc)
    return prob, cb
end

function setup_simulation(; greet = false)
    t0 = 0.0
    tf = 60 * 60.0 * 6
    Δt = 450.0
    nelements = (101, 15)
    if greet
        @info "Run: Global Soil-Canopy-Snow Model"
        @info "Resolution: $nelements"
        @info "Timestep: $Δt s"
        @info "Duration: $(tf - t0) s"
    end

    prob, cb = setup_prob(t0, tf, Δt; nelements)

    # Define timestepper and ODE algorithm
    stepper = CTS.ARS111()
    ode_algo = CTS.IMEXAlgorithm(
        stepper,
        CTS.NewtonsMethod(
            max_iters = 3,
            update_j = CTS.UpdateEvery(CTS.NewNewtonIteration),
        ),
    )
    return prob, ode_algo, Δt, cb
end
parsed_args = parse_commandline()
profiler = parsed_args["profiler"]
@info "Starting profiling with $profiler"
if profiler == "flamegraph"
    prob, ode_algo, Δt, cb = setup_simulation(; greet = true)
    @info "Starting profiling"
    SciMLBase.solve(prob, ode_algo; dt = Δt, callback = cb, adaptive = false)
    MAX_PROFILING_TIME_SECONDS = 500
    MAX_PROFILING_SAMPLES = 100
    time_now = time()
    timings_s = Float64[]
    while (time() - time_now) < MAX_PROFILING_TIME_SECONDS &&
        length(timings_s) < MAX_PROFILING_SAMPLES
        lprob, lode_algo, lΔt, lcb = setup_simulation()
        push!(
            timings_s,
            ClimaComms.@elapsed device SciMLBase.solve(
                lprob,
                lode_algo;
                dt = lΔt,
                callback = lcb,
            )
        )
    end
    num_samples = length(timings_s)
    average_timing_s = round(sum(timings_s) / num_samples, sigdigits = 3)
    max_timing_s = round(maximum(timings_s), sigdigits = 3)
    min_timing_s = round(minimum(timings_s), sigdigits = 3)
    std_timing_s = round(
        sqrt(sum(((timings_s .- average_timing_s) .^ 2) / num_samples)),
        sigdigits = 3,
    )
    @info "Num samples: $num_samples"
    @info "Average time: $(average_timing_s) s"
    @info "Max time: $(max_timing_s) s"
    @info "Min time: $(min_timing_s) s"
    @info "Standard deviation time: $(std_timing_s) s"
    @info "Done profiling"

    if ClimaComms.device() isa ClimaComms.CUDADevice
        import CUDA
        lprob, lode_algo, lΔt, lcb = setup_simulation()
        p = CUDA.@profile SciMLBase.solve(
            lprob,
            lode_algo;
            dt = lΔt,
            callback = lcb,
        )
        # use "COLUMNS" to set how many horizontal characters to crop:
        # See https://github.com/ronisbr/PrettyTables.jl/issues/11#issuecomment-2145550354
        envs = ("COLUMNS" => 120,)
        withenv(envs...) do
            io = IOContext(
                stdout,
                :crop => :horizontal,
                :limit => true,
                :displaysize => displaysize(),
            )
            show(io, p)
        end
        println()
    else # Flame graphs can be misleading on gpus, so we only create them on CPU
        prob, ode_algo, Δt, cb = setup_simulation()
        Profile.@profile SciMLBase.solve(prob, ode_algo; dt = Δt, callback = cb)
        results = Profile.fetch()
        flame_file = joinpath(outdir, "flame_$device_suffix.html")
        ProfileCanvas.html_file(flame_file, results)
        @info "Saved compute flame to $flame_file"

        prob, ode_algo, Δt, cb = setup_simulation()
        Profile.Allocs.@profile sample_rate = 0.0025 SciMLBase.solve(
            prob,
            ode_algo;
            dt = Δt,
            callback = cb,
        )
        results = Profile.Allocs.fetch()
        profile = ProfileCanvas.view_allocs(results)
        alloc_flame_file = joinpath(outdir, "alloc_flame_$device_suffix.html")
        ProfileCanvas.html_file(alloc_flame_file, profile)
        @info "Saved allocation flame to $alloc_flame_file"
    end
    if get(ENV, "BUILDKITE_PIPELINE_SLUG", nothing) == "climaland-benchmark"
        PREVIOUS_BEST_TIME = 0.67
        if average_timing_s > PREVIOUS_BEST_TIME + std_timing_s
            @info "Possible performance regression, previous average time was $(PREVIOUS_BEST_TIME)"
        elseif average_timing_s < PREVIOUS_BEST_TIME - std_timing_s
            @info "Possible significant performance improvement, please update PREVIOUS_BEST_TIME in $(@__DIR__)"
        end
        @testset "Performance" begin
            @test PREVIOUS_BEST_TIME - 2std_timing_s <=
                  average_timing_s <=
                  PREVIOUS_BEST_TIME + 2std_timing_s
        end
    end
elseif profiler == "nsight"
    prob, ode_algo, Δt, cb = setup_simulation(; greet = true)
    integrator = SciMLBase.init(prob, ode_algo; dt = Δt, callback = cb)
    SciMLBase.step!(integrator)
    SciMLBase.step!(integrator)
    SciMLBase.step!(integrator)
    SciMLBase.step!(integrator)
else
    @error("Profiler choice not supported.")
end
