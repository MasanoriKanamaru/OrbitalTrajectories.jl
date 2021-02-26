module SpiceUtils

    using Downloads
    using Dates
    using SPICE
    using ModelingToolkit
    using Pkg.MiniProgressBars
    using Pkg.Artifacts
    using ForwardDiff
    using StaticArrays

    export mass_fraction
    export state_to_synodic, state_from_synodic
    export pos_to_synodic, pos_from_synodic

    function __init__()
        # Load a set of default SPICE kernels for this project
        furnsh(readdir(artifact"spice_kernels", join=true)...)
        nothing
    end

    const artifacts_toml = find_artifacts_toml(@__DIR__)
    function load_ephemerides(body_name)
        # Do we need to load any ephemerides for this body?
        body_name = lowercase(String(body_name))
        body_ID   = bodn2c(body_name)
        body_idx_in_system = body_ID % 100

        if body_idx_in_system == 0 || body_idx_in_system == 99
            # This is the primary (planetary) body, so is already included in the default kernels.
            return true
        end

        # Otherwise, let's load the planetary system
        system_ID = (body_ID ÷ 100) + 99
        system_name = bodc2n(system_ID)
        artifact_name = "$(system_name)_ephemerides"

        # Check if we've defined a default kernel for this planetary system.
        meta = artifact_meta(artifact_name, artifacts_toml)
        if isnothing(meta)
            @warn """No default SPICE kernels specified for the $(titlecase(system_name)) system.
            You may need to download and then load them manually with `SPICE.furnsh`."""
            return false
        end
        
        # Check if the kernel has already been downloaded before, and if not, download it.
        meta_hash = Base.SHA1(meta["git-tree-sha1"])
        kernel_path = artifact_path(meta_hash)
        if !artifact_exists(meta_hash)

            # Progress bar based on Pkg.PlatformEngines code (MIT "Expact" License, Copyright (c) 2017: Stefan Karpinski.)
            progress = begin
                bar = MiniProgressBar(header="Downloading $(system_name) system ephemerides", color=Base.info_color())
                io = stdout
                start_progress(io, bar)
                (total, now) -> begin
                    bar.max = total
                    bar.current = now
                    show_progress(io, bar)
                end
            end

            try
                Downloads.download(meta["download"][1]["url"], kernel_path; progress)
            finally
                end_progress(io, bar)
            end
        end

        # Load the planetary system kernel.
        furnsh(kernel_path)
        return true
    end

    @doc "Get a target body position from SPICE kernels."
    get_pos(t, target, reference; relative="ECLIPJ2000") = SVector{3,Float64}(spkpos(String(target), t, relative, "none", String(reference))[1])
    get_pos(t::ForwardDiff.Dual, target, reference; kwargs...) = get_pos(ForwardDiff.value(t), String(target), String(reference); kwargs...)
    get_pos(t::Num, tgt, ref) = get_pos(t, Num(tgt), Num(ref))
    ModelingToolkit.@register get_pos(t, target, reference)

    @doc "Get a target body state from SPICE kernels"
    get_state(t, target, reference; relative="ECLIPJ2000") = SVector{6,Float64}(spkezr(String(target), t, relative, "none", String(reference))[1])
    get_state(t::ForwardDiff.Dual, target, reference; kwargs...) = get_state(ForwardDiff.value(t), target, reference; kwargs...)

    @doc "Get body gravitational constant (GM) from SPICE kernels"
    get_GM(body::String) = bodvrd(body, "GM")[1]
    get_GM(body::Symbol) = get_GM(String(body))
    get_GM(body::Number) = get_GM(bodc2n(body))

    @doc "Get the mass fraction of two bodies (smaller mass divided by total mass)"
    mass_fraction(b1::Symbol, b2::Symbol) = mass_fraction(String(b1), String(b2))
    function mass_fraction(body_1::String, body_2::String)
        mass_1 = bodvrd(body_1, "GM")[1]
        mass_2 = bodvrd(body_2, "GM")[1]
        min(mass_1, mass_2) ./ (mass_1 .+ mass_2)
    end

    # Dynamic frame ID should be between 1400000 to 2000000 (added a bit of margin for rand) as per
    # https://naif.jpl.nasa.gov/pub/naif/toolkit_docs/C/req/frames.html#Selecting%20a%20Frame%20ID
    const INIT_DYNAMIC_FRAME_IDX = rand(1400000:1900000)
    const DYNAMIC_FRAMES_TYPE = Dict{Tuple{Symbol,Symbol},Tuple{Int,String}}
    DYNAMIC_FRAMES = DYNAMIC_FRAMES_TYPE()

    @doc """ 
    Automatically build and return a dynamic frame for a synodic
    reference (b1 is the observer, b2 is the target).
    """
    function dynamic_synodic_frame(b1::Symbol, b2::Symbol; reference="ECLIPJ2000")
        if (b1, b2) ∉ keys(DYNAMIC_FRAMES::DYNAMIC_FRAMES_TYPE)
            # XXX: Maximum size of the frame name is limited so we use the body numbers.
            bodies = bodn2c.((b1, b2))
            frame_name = "$(bodies[1])_$(bodies[2])_SYNODIC"
            path, io = mktemp()
            ID = INIT_DYNAMIC_FRAME_IDX + length(DYNAMIC_FRAMES::DYNAMIC_FRAMES_TYPE)
            write(io, 
            """ \\begindata

                FRAME_$(frame_name)        = $(ID)
                FRAME_$(ID)_NAME           = '$(frame_name)'
                FRAME_$(ID)_CLASS          = 5
                FRAME_$(ID)_CLASS_ID       = $(ID)
                FRAME_$(ID)_CENTER         = $(bodies[1])
                FRAME_$(ID)_RELATIVE       = '$(reference)'
                FRAME_$(ID)_DEF_STYLE      = 'PARAMETERIZED'
                FRAME_$(ID)_ROTATION_STATE = 'ROTATING'
                FRAME_$(ID)_FAMILY         = 'TWO-VECTOR'
                FRAME_$(ID)_PRI_AXIS       = 'X'
                FRAME_$(ID)_PRI_VECTOR_DEF = 'OBSERVER_TARGET_POSITION'
                FRAME_$(ID)_PRI_OBSERVER   = $(bodies[1])
                FRAME_$(ID)_PRI_TARGET     = $(bodies[2])
                FRAME_$(ID)_PRI_ABCORR     = 'NONE'
                FRAME_$(ID)_SEC_AXIS       = 'Y'
                FRAME_$(ID)_SEC_VECTOR_DEF = 'OBSERVER_TARGET_VELOCITY'
                FRAME_$(ID)_SEC_OBSERVER   = $(bodies[1])
                FRAME_$(ID)_SEC_TARGET     = $(bodies[2])
                FRAME_$(ID)_SEC_FRAME      = '$(reference)'
                FRAME_$(ID)_SEC_ABCORR     = 'NONE'
            """)
            close(io)

            (DYNAMIC_FRAMES::DYNAMIC_FRAMES_TYPE)[(b1, b2)] = (ID, frame_name)
            @info "Importing new $frame_name kernel from $(path)"
            furnsh(path)
        else
            ID, frame_name = (DYNAMIC_FRAMES::DYNAMIC_FRAMES_TYPE)[(b1, b2)]
        end
        return frame_name
    end

    # TODO: Fix up the SpiceUtils interface so the arguments are more consistently ordered.
    state_to_synodic(b1, b2, t; reference="ECLIPJ2000") = sxform(reference, dynamic_synodic_frame(b1, b2; reference=reference), t)
    state_to_synodic(b1, b2, t::ForwardDiff.Dual; kwargs...) = state_to_synodic(b1, b2, ForwardDiff.value(t); kwargs...)
    state_from_synodic(args...; kwargs...) = inv(state_to_synodic(args...; kwargs...))

    pos_to_synodic(b1, b2, t; reference="ECLIPJ2000") = pxform(reference, dynamic_synodic_frame(b1, b2; reference=reference), t)
    pos_to_synodic(b1, b2, t::ForwardDiff.Dual; kwargs...) = pos_to_synodic(b1, b2, ForwardDiff.value(t); kwargs...)
    pos_from_synodic(args...; kwargs...) = inv(pos_to_synodic(args...; kwargs...))

end