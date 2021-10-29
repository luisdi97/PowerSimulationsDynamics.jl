function mass_matrix_inner_entries!(
    mass_matrix,
    inner_control::IC,
    global_index::Base.ImmutableDict{Symbol, Int64},
) where {IC <: PSY.InnerControl}
    @debug "Using default mass matrix entries $IC"
end

function mass_matrix_inner_entries!(
    mass_matrix,
    inner_control::PSY.RECurrentControlB,
    global_index::ImmutableDict{Symbol, Int64},
)
    mass_matrix[global_index[:Vt_filt], global_index[:Vt_filt]] =
        PSY.get_T_rv(inner_control)
    if PSY.get_Q_Flag(inner_control) == 0
        mass_matrix[global_index[:I_icv], global_index[:I_icv]] =
            PSY.get_T_iq(inner_control)
    end
end

#####################################################
### Auxiliary ODE calculations via Flags dispatch ###
#####################################################

### Inner Controllers ###

#Q_Flag = 0
function _mdl_ode_RE_inner_controller_B!(
    inner_controller_ode::AbstractArray{<:ACCEPTED_REAL_TYPES},
    inner_controller_states::AbstractArray{<:ACCEPTED_REAL_TYPES},
    ::Type{Base.RefValue{0}},
    inner_control::PSY.RECurrentControlB,
    dynamic_device::DynamicWrapper{
        PSY.DynamicInverter{C, O, PSY.RECurrentControlB, DC, P, F},
    },
    inner_vars::AbstractVector,
) where {
    C <: PSY.Converter,
    O <: PSY.OuterControl,
    DC <: PSY.DCSource,
    P <: PSY.FrequencyEstimator,
    F <: PSY.Filter,
}
    #Obtain inner variables for component
    V_t = sqrt(inner_vars[Vr_inv_var]^2 + inner_vars[Vi_inv_var]^2)
    Ip_oc = inner_vars[Id_oc_var]
    Iq_oc = inner_vars[Iq_oc_var]

    #Get Current Controller parameters
    PQ_Flag = PSY.get_PQ_Flag(inner_control)
    dbd1, dbd2 = PSY.get_dbd_pnts(inner_control)
    K_qv = PSY.get_K_qv(inner_control)
    I_ql1, I_qh1 = PSY.get_Iqinj_lim(inner_control)
    V_ref0 = PSY.get_V_ref0(inner_control)

    #Read local states
    Vt_filt = inner_controller_states[1]
    I_icv = inner_controller_states[2]

    #Compute additional states
    V_err = deadband_function(V_ref0 - Vt_filt, dbd1, dbd2)
    Iq_inj = clamp(K_qv * V_err, I_ql1, I_qh1)
    Iq_cmd = I_icv + Iq_inj
    Ip_min, Ip_max, Iq_min, Iq_max =
        current_limit_logic(inner_control, Base.RefValue{PQ_Flag}, Vt_filt, Ip_oc, Iq_cmd)
    Iq_cmd = clamp(Iq_cmd, Iq_min, Iq_max)
    Ip_cmd = clamp(Ip_oc, Ip_min, Ip_max)

    #ODE update
    inner_controller_ode[1] = V_t - Vt_filt
    inner_controller_ode[2] = Iq_oc - I_icv

    #Update Inner Vars
    inner_vars[Id_ic_var] = Ip_cmd
    inner_vars[Iq_ic_var] = Iq_cmd
end

#Q_Flag = 1
function _mdl_ode_RE_inner_controller_B!(
    inner_controller_ode::AbstractArray{<:ACCEPTED_REAL_TYPES},
    inner_controller_states::AbstractArray{<:ACCEPTED_REAL_TYPES},
    ::Type{Base.RefValue{1}},
    inner_control::PSY.RECurrentControlB,
    dynamic_device::DynamicWrapper{
        PSY.DynamicInverter{C, O, PSY.RECurrentControlB, DC, P, F},
    },
    inner_vars::AbstractVector,
) where {
    C <: PSY.Converter,
    O <: PSY.OuterControl,
    DC <: PSY.DCSource,
    P <: PSY.FrequencyEstimator,
    F <: PSY.Filter,
}
    #Obtain inner variables for component
    V_t = sqrt(inner_vars[Vr_inv_var]^2 + inner_vars[Vi_inv_var]^2)
    Ip_oc = inner_vars[Id_oc_var]
    V_oc = inner_vars[V_oc_var]

    #Get Current Controller parameters
    PQ_Flag = PSY.get_PQ_Flag(inner_control)
    K_vp = PSY.get_K_vp(inner_control)
    K_vi = PSY.get_K_vi(inner_control)

    #Read local states
    Vt_filt = inner_controller_states[1]
    ξ_icv = inner_controller_states[2]

    #Compute additional states
    V_err = deadband_function(V_ref0 - Vt_filt, dbd1, dbd2)
    Iq_inj = clamp(K_qv * V_err, I_ql1, I_qh1)
    #To do: Limits on PI non-windup
    I_icv = K_vp * V_oc + K_vi * ξ_icv
    Iq_cmd = I_icv + Iq_inj
    Ip_min, Ip_max, Iq_min, Iq_max =
        current_limit_logic(inner_control, Base.RefValue{PQ_Flag}, Vt_filt, Ip_oc, Iq_cmd)
    Iq_cmd = clamp(Iq_cmd, Iq_min, Iq_max)
    Ip_cmd = clamp(Ip_oc, Ip_min, Ip_max)

    #ODE update
    inner_controller_ode[1] = V_t - Vt_filt
    inner_controller_ode[2] = V_oc

    #Update Inner Vars
    inner_vars[Id_ic_var] = Ip_cmd
    inner_vars[Iq_ic_var] = Iq_cmd
end

############################################
### ODE calculations via device dispatch ###
############################################

function mdl_inner_ode!(
    device_states::AbstractArray{<:ACCEPTED_REAL_TYPES},
    output_ode::AbstractArray{<:ACCEPTED_REAL_TYPES},
    inner_vars::AbstractArray{<:ACCEPTED_REAL_TYPES},
    dynamic_device::DynamicWrapper{
        PSY.DynamicInverter{C, O, PSY.VoltageModeControl, DC, P, F},
    },
) where {
    C <: PSY.Converter,
    O <: PSY.OuterControl,
    DC <: PSY.DCSource,
    P <: PSY.FrequencyEstimator,
    F <: PSY.Filter,
}

    #Obtain external states inputs for component
    external_ix = get_input_port_ix(dynamic_device, PSY.VoltageModeControl)
    Ir_filter = device_states[external_ix[1]]
    Ii_filter = device_states[external_ix[2]]
    Ir_cnv = device_states[external_ix[3]]
    Ii_cnv = device_states[external_ix[4]]
    Vr_filter = device_states[external_ix[5]]
    Vi_filter = device_states[external_ix[6]]

    #Obtain inner variables for component
    ω_oc = inner_vars[ω_oc_var]
    θ_oc = inner_vars[θ_oc_var]
    v_refr = inner_vars[V_oc_var]
    Vdc = inner_vars[Vdc_var]

    #Get Voltage Controller parameters
    inner_control = PSY.get_inner_control(dynamic_device)
    filter = PSY.get_filter(dynamic_device)
    kpv = PSY.get_kpv(inner_control)
    kiv = PSY.get_kiv(inner_control)
    kffi = PSY.get_kffi(inner_control)
    cf = PSY.get_cf(filter)
    rv = PSY.get_rv(inner_control)
    lv = PSY.get_lv(inner_control)

    #Get Current Controller parameters
    kpc = PSY.get_kpc(inner_control)
    kic = PSY.get_kic(inner_control)
    kffv = PSY.get_kffv(inner_control)
    lf = PSY.get_lf(filter)
    ωad = PSY.get_ωad(inner_control)
    kad = PSY.get_kad(inner_control)

    #Obtain indices for component w/r to device
    local_ix = get_local_state_ix(dynamic_device, PSY.VoltageModeControl)

    #Define internal states for frequency estimator
    internal_states = @view device_states[local_ix]
    ξ_d = internal_states[1]
    ξ_q = internal_states[2]
    γ_d = internal_states[3]
    γ_q = internal_states[4]
    ϕ_d = internal_states[5]
    ϕ_q = internal_states[6]

    #Transformations to dq frame
    I_dq_filter = ri_dq(θ_oc + pi / 2) * [Ir_filter; Ii_filter]
    I_dq_cnv = ri_dq(θ_oc + pi / 2) * [Ir_cnv; Ii_cnv]
    V_dq_filter = ri_dq(θ_oc + pi / 2) * [Vr_filter; Vi_filter]

    ### Compute 6 states ODEs (D'Arco EPSR122 Model) ###
    ## SRF Voltage Control w/ Virtual Impedance ##
    #Virtual Impedance
    Vd_filter_ref = (v_refr - rv * I_dq_filter[d] + ω_oc * lv * I_dq_filter[q])
    Vq_filter_ref = (-rv * I_dq_filter[q] - ω_oc * lv * I_dq_filter[d])

    #Voltage Control ODEs
    #PI Integrator (internal state)
    output_ode[local_ix[1]] = (Vd_filter_ref - V_dq_filter[d])
    output_ode[local_ix[2]] = (Vq_filter_ref - V_dq_filter[q])

    #Output Control Signal - Links to SRF Current Controller
    Id_cnv_ref = (
        kpv * (Vd_filter_ref - V_dq_filter[d]) + kiv * ξ_d - cf * ω_oc * V_dq_filter[q] + kffi * I_dq_filter[d]
    )

    Iq_cnv_ref = (
        kpv * (Vq_filter_ref - V_dq_filter[q]) +
        kiv * ξ_q +
        cf * ω_oc * V_dq_filter[d] +
        kffi * I_dq_filter[q]
    )

    ## SRF Current Control ##
    #Current Control ODEs
    #PI Integrator (internal state)
    output_ode[local_ix[3]] = Id_cnv_ref - I_dq_cnv[d]
    output_ode[local_ix[4]] = Iq_cnv_ref - I_dq_cnv[q]

    #References for Converter Output Voltage
    Vd_cnv_ref = (
        kpc * (Id_cnv_ref - I_dq_cnv[d]) + kic * γ_d - ω_oc * lf * I_dq_cnv[q] +
        kffv * V_dq_filter[d] - kad * (V_dq_filter[d] - ϕ_d)
    )
    Vq_cnv_ref = (
        kpc * (Iq_cnv_ref - I_dq_cnv[q]) +
        kic * γ_q +
        ω_oc * lf * I_dq_cnv[d] +
        kffv * V_dq_filter[q] - kad * (V_dq_filter[q] - ϕ_q)
    )

    #Active Damping LPF (internal state)
    output_ode[local_ix[5]] = ωad * V_dq_filter[d] - ωad * ϕ_d
    output_ode[local_ix[6]] = ωad * V_dq_filter[q] - ωad * ϕ_q

    #Update inner_vars
    #Modulation Commands to Converter
    inner_vars[md_var] = Vd_cnv_ref / Vdc
    inner_vars[mq_var] = Vq_cnv_ref / Vdc
end

function mdl_inner_ode!(
    device_states::AbstractArray{<:ACCEPTED_REAL_TYPES},
    output_ode::AbstractArray{<:ACCEPTED_REAL_TYPES},
    inner_vars::AbstractArray{<:ACCEPTED_REAL_TYPES},
    dynamic_device::DynamicWrapper{
        PSY.DynamicInverter{C, O, PSY.CurrentModeControl, DC, P, F},
    },
) where {
    C <: PSY.Converter,
    O <: PSY.OuterControl,
    DC <: PSY.DCSource,
    P <: PSY.FrequencyEstimator,
    F <: PSY.Filter,
}

    #Obtain external states inputs for component
    external_ix = get_input_port_ix(dynamic_device, PSY.CurrentModeControl)
    # Ir_filter = device_states[external_ix[1]]
    # Ii_filter = device_states[external_ix[2]]
    Ir_cnv = device_states[external_ix[3]]
    Ii_cnv = device_states[external_ix[4]]
    Vr_filter = device_states[external_ix[5]]
    Vi_filter = device_states[external_ix[6]]

    #Obtain inner variables for component
    ω_oc = inner_vars[ω_oc_var]
    θ_oc = inner_vars[θ_oc_var]
    Vdc = inner_vars[Vdc_var]

    #Get Current Controller parameters
    inner_control = PSY.get_inner_control(dynamic_device)
    filter = PSY.get_filter(dynamic_device)
    kpc = PSY.get_kpc(inner_control)
    kic = PSY.get_kic(inner_control)
    kffv = PSY.get_kffv(inner_control)
    lf = PSY.get_lf(filter)

    #Obtain indices for component w/r to device
    local_ix = get_local_state_ix(dynamic_device, PSY.CurrentModeControl)

    #Define internal states for frequency estimator
    internal_states = @view device_states[local_ix]
    γ_d = internal_states[1]
    γ_q = internal_states[2]

    #Transformations to dq frame
    I_dq_cnv = ri_dq(θ_oc + pi / 2) * [Ir_cnv; Ii_cnv]
    V_dq_filter = ri_dq(θ_oc + pi / 2) * [Vr_filter; Vi_filter]

    #Input Control Signal - Links to SRF Current Controller
    Id_cnv_ref = inner_vars[Id_oc_var]
    Iq_cnv_ref = inner_vars[Iq_oc_var]

    #Current Control ODEs
    #PI Integrator (internal state)
    output_ode[local_ix[1]] = Id_cnv_ref - I_dq_cnv[d]
    output_ode[local_ix[2]] = Iq_cnv_ref - I_dq_cnv[q]

    #References for Converter Output Voltage
    Vd_cnv_ref = (
        kpc * (Id_cnv_ref - I_dq_cnv[d]) + kic * γ_d - ω_oc * lf * I_dq_cnv[q] +
        kffv * V_dq_filter[d]
    )
    Vq_cnv_ref = (
        kpc * (Iq_cnv_ref - I_dq_cnv[q]) +
        kic * γ_q +
        ω_oc * lf * I_dq_cnv[d] +
        kffv * V_dq_filter[q]
    )

    #Update inner_vars
    #Modulation Commands to Converter
    inner_vars[md_var] = Vd_cnv_ref / Vdc
    inner_vars[mq_var] = Vq_cnv_ref / Vdc
end

function mdl_inner_ode!(
    device_states::AbstractArray{<:ACCEPTED_REAL_TYPES},
    output_ode::AbstractArray{<:ACCEPTED_REAL_TYPES},
    inner_vars::AbstractArray{<:ACCEPTED_REAL_TYPES},
    dynamic_device::DynamicWrapper{
        PSY.DynamicInverter{C, O, PSY.RECurrentControlB, DC, P, F},
    },
) where {
    C <: PSY.Converter,
    O <: PSY.OuterControl,
    DC <: PSY.DCSource,
    P <: PSY.FrequencyEstimator,
    F <: PSY.Filter,
}
    #Get Current Controller parameters
    inner_control = PSY.get_inner_control(dynamic_device)
    Q_Flag = PSY.get_Q_Flag(inner_control)

    #Obtain indices for component w/r to device
    local_ix = get_local_state_ix(dynamic_device, PSY.RECurrentControlB)
    #Define internal states for Inner Control
    internal_states = @view device_states[local_ix]
    internal_ode = @view output_ode[local_ix]

    # TODO: Voltage Dip Freeze logic

    #Dispatch inner controller ODE calculation
    _mdl_ode_RE_inner_controller_B!(
        internal_ode,
        internal_states,
        Base.RefValue{Q_Flag},
        inner_control,
        dynamic_device,
        inner_vars,
    )
end