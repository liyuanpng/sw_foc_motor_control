/**
 * The copyrights, all other intellectual and industrial
 * property rights are retained by XMOS and/or its licensors.
 * Terms and conditions covering the use of this code can
 * be found in the Xmos End User License Agreement.
 *
 * Copyright XMOS Ltd 2013
 *
 * In the case where this code is a modification of existing code
 * under a separate license, the separate license terms are shown
 * below. The modifications to the code are still covered by the
 * copyright notice above.
 **/

#include "inner_loop.h"

/*****************************************************************************/
static void init_error_data( // Initialise Error-handling data
	ERR_DATA_TYP &err_data_s // Reference to structure containing data for error-handling
)
{
	int err_cnt; // phase counter


	err_data_s.err_flgs = 0; 	// Clear fault detection flags

	// Loop through error-types and assign default values
	for (err_cnt=0; err_cnt<NUM_ERR_TYPS; err_cnt++)
	{
		err_data_s.line[err_cnt] = -1; 	// Initialised to unassigned line number
		err_data_s.err_cnt[err_cnt] = 0; 	// Initialised to unassigned line number
		err_data_s.err_lim[err_cnt] = 0; 	// Initialised to unassigned line number
		safestrcpy( err_data_s.err_strs[err_cnt].str ,"No Message! Please add in function init_motor()" );
	} // for err_cnt

	// Add NON-default limits here ...
	err_data_s.err_lim[OVERCURRENT_ERR] = OC_ERR_LIM;

	// Add NON-default error-strings here ...
	safestrcpy( err_data_s.err_strs[OVERCURRENT_ERR].str ,"Over-Current Detected" );
	safestrcpy( err_data_s.err_strs[UNDERVOLTAGE_ERR].str ,"Under-Voltage Detected" );
	safestrcpy( err_data_s.err_strs[STALLED_ERR].str ,"Motor Stalled Persistently" );
	safestrcpy( err_data_s.err_strs[DIRECTION_ERR].str ,"Motor Spinning In Wrong Direction!" );
	safestrcpy( err_data_s.err_strs[SPEED_ERR].str ,"Motor Exceeded Maximim Speed" );

} // init_error_data
/*****************************************************************************/
static void init_blend_data( // Initialise blending data for 'TRANSIT state'
	MOTOR_DATA_TYP &motor_s // Reference to structure containing motor data
)
/* Calculate time in TRANSIT state based on Requested open-loop Vq ...
 * Using at least one electrical cycle per  1024 Vq units
 * Then compute blending function data, so bit-shift division can be used.
 */
{
	unsigned diff_theta; // blending period (measured as QEI angle positions)
	int Vd_diff; // Vd difference
	int Vq_diff; // Vq difference
	int max_diff; // Max Voltage difference
	int sum_bits; // Sum of resolution bits
	int blend_bits; // Bit resolution of blending increment


	// Check bit precision ...
	assert(BLEND_BITS >= 0); // ERROR: Investigate definition in inner_loop.h
	assert(31 > (QEI_RES_BITS + QEI_UQ_BITS + BLEND_BITS)); // ERROR: QEI_UQ_BITS too large

	sum_bits = QEI_RES_BITS + QEI_UQ_BITS + PWM_RES_BITS; // 28

	// WARNING: Definition of RF_DIV_RPM_BITS assumes values for Reference_Freq and Starting_Speed. See inner_loop.h
	if (sum_bits < RF_DIV_RPM_BITS)
	{ // Update
		blend_bits = RF_DIV_RPM_BITS - sum_bits; // Bit resolution of blending increment
		motor_s.open_period = (1 << (PWM_RES_BITS - sum_bits));	// NB Forces update after a No. of PWM periods
	} // if (sum_bits < RF_DIV_RPM_BITS )
	else
	{
		blend_bits = 0; // Bit resolution of blending increment
		motor_s.open_period = 0;	// NB Forces update every PWM period
		motor_s.open_uq_inc = (1 << (sum_bits - RF_DIV_RPM_BITS)); // Increment to Upscaled theta value during open-loop phase
	} // else !(sum_bits < RF_DIV_RPM_BITS )

	// Check for -ve spin
	if (0 > motor_s.targ_vel)
	{ // Negative spin direction
		motor_s.open_uq_inc = -motor_s.open_uq_inc; // Spin in Negative direction
	} // if (0 > motor_s.targ_vel)

	motor_s.blend_inc = (1 << blend_bits); // Blending weight increment for during TRANSIT state

	// Evaluate state termination conditions (NB require power-of-2 for TRANSIT state blending function)
	motor_s.search_theta = QEI_PER_PAIR; // Upscaled theta value at end of 'SEARCH state'

	// This section uses at least one electrical cycle per 1024 Vq values ..

	// Evaluate Vd & Vq differences
	Vd_diff = motor_s.vect_data[D_ROTA].end_open_V - motor_s.vect_data[D_ROTA].start_open_V;
	Vq_diff = motor_s.vect_data[Q_ROTA].end_open_V - motor_s.vect_data[Q_ROTA].start_open_V;

	motor_s.vect_data[D_ROTA].diff_V = (Vd_diff << blend_bits);
	motor_s.vect_data[Q_ROTA].diff_V = (Vq_diff << blend_bits);

	Vd_diff = abs(Vd_diff); // Absolute Vd difference
	Vq_diff = abs(Vq_diff); // Absolute Vq difference

	max_diff = Vq_diff; // Preset to Vq difference

	// Check if Vd difference is larger
	if (max_diff < Vd_diff) max_diff = Vd_diff;

	// Convert voltage-difference to electrical-cycles
	motor_s.trans_cycles = (max_diff + VOLT_DIFF_MASK) >> VOLT_DIFF_BITS;
	if (motor_s.trans_cycles < 1) motor_s.trans_cycles = 1; // Ensure at least one cycle

	diff_theta = QEI_PER_PAIR * motor_s.trans_cycles; // No of Upscaled QEI positions (theta)
	motor_s.trans_theta = motor_s.search_theta + diff_theta; // theta at end of 'TRANSIT state'

	motor_s.blend_weight = motor_s.blend_inc; // Preset 1st blending weight
} // init_blend_data
/****************************************************************************/
static void init_pid_data( // Initialise PID data
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
{
	int pid_cnt; // PID counter


	// Convert Floating-point PID constants to fixed-point arithmetic

	init_all_pid_consts( motor_s.pid_consts[ID_PID] ,1.0 ,0.0058 ,0.0 );
	init_all_pid_consts( motor_s.pid_consts[IQ_PID] ,8.0 ,0.017 ,0.0 ); //MB~
// init_all_pid_consts( motor_s.pid_consts[IQ_PID] ,16.0 ,0.000001 ,0.0 ); //CW~

	init_all_pid_consts( motor_s.pid_consts[SPEED_PID]	,4.0 ,0.00012 ,0.0 ); //MB~
// init_all_pid_consts( motor_s.pid_consts[SPEED_PID] ,4.0 ,0.0 ,0.0 ); //CW~

if (motor_s.id)
{
	acquire_lock(); printint(motor_s.id);
	printstr(": Kp="); printint(motor_s.pid_consts[IQ_PID].K_p);
	printstr(": Kd="); printint(motor_s.pid_consts[IQ_PID].K_d);
	printstr(": Ki="); printintln(motor_s.pid_consts[IQ_PID].K_i);
	release_lock();
}
	motor_s.pid_Id = 0;	// Output from radial current PID
	motor_s.pid_Iq = 0;	// Output from tangential current PID
	motor_s.pid_veloc = 0;	// Output from velocity PID

	motor_s.pid_preset = 1; // Force preset of PID values after restart

	// Initialise PID regulators. NB Clears PID sum
	for (pid_cnt = 0; pid_cnt < NUM_PIDS; pid_cnt++)
	{
		initialise_pid( motor_s.pid_regs[pid_cnt] );
	} // for pid_cnt

} // init_pid_data
/*****************************************************************************/
static void init_rotation_component( // Initialise data for one component of rotation vector
	MOTOR_DATA_TYP &motor_s, // Reference to structure containing motor data
	ROTA_VECT_ENUM comp_id, // Indentifier for component to initialise
	int start_V_openloop, // Component voltage at start of open-loop state
	int end_V_openloop, //  Component voltage at end of open-loop state
	int req_V_closedloop // Initial component voltage for closed-loop state
)
{
	motor_s.vect_data[comp_id].start_open_V = start_V_openloop;  // Voltage during open-loop mode (start-up)
	motor_s.vect_data[comp_id].trans_V = start_V_openloop;  // Starting voltage for TRANSIT state
	motor_s.vect_data[comp_id].set_V = start_V_openloop; // Initialise driving voltage for closed-loop mode
	motor_s.vect_data[comp_id].end_open_V = end_V_openloop; // Initialise requested voltage for open-loop mode
	motor_s.vect_data[comp_id].req_closed_V = req_V_closedloop; // Initialise requested voltage for closed-loop mode
	motor_s.vect_data[comp_id].prev_V = start_V_openloop;  // Preset previously used demand voltage value
	motor_s.vect_data[comp_id].diff_V = 0; // Difference between Start and Requested Voltage
	motor_s.vect_data[comp_id].rem_V = 0; // Voltage remainder, used in error diffusion
	motor_s.vect_data[comp_id].err_V = 0; // Set Voltage remainder, used in error diffusion

	motor_s.vect_data[comp_id].inp_I = 0; // Initialise input estimated current
	motor_s.vect_data[comp_id].est_I = 0; // Initialise (possibly filtered) output estimated current
	motor_s.vect_data[comp_id].prev_I = 0; // Initialise previous estimated current
	motor_s.vect_data[comp_id].rem_I = 0; // Initialise remainder used in error diffusion
} // init_rotation_component
/*****************************************************************************/
static void init_velocity_data( // Initialise velocity dependent data
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
{
	int start_D; // Vd value at start of open-loop state
	int start_Q; // Vq value at start of open-loop state
	int end_D; // Vd value at end of open-loop state
	int end_Q; // Vq value at end of open-loop state
	int req_D; // Initial requested closed-loop Vd value
	int req_Q; // Initial requested closed-loop Vq value


	// Use Park Transform to convert Absolute-Voltage & Angle, to equivalent 2-D vector components (Vd, Vq)

	if (0 > motor_s.targ_vel)
	{ // Negative spin direction
		park_transform( start_D ,start_Q ,0 ,START_VOLT_OPENLOOP ,(-START_GAMMA_OPENLOOP) );
		park_transform( end_D ,end_Q ,0 ,END_VOLT_OPENLOOP ,(-END_GAMMA_OPENLOOP) );
		park_transform( req_D ,req_Q ,0 ,REQ_VOLT_CLOSEDLOOP ,(-REQ_GAMMA_CLOSEDLOOP) );
	} // if (0 > motor_s.targ_vel)
	else
	{ // Positive spin direction
		park_transform( start_D ,start_Q ,0 ,START_VOLT_OPENLOOP ,START_GAMMA_OPENLOOP );
		park_transform( end_D ,end_Q ,0 ,END_VOLT_OPENLOOP ,END_GAMMA_OPENLOOP );
		park_transform( req_D ,req_Q ,0 ,REQ_VOLT_CLOSEDLOOP ,REQ_GAMMA_CLOSEDLOOP );
	} // else !(0 > motor_s.targ_vel)

	// Initialise each component of rotating vector
	init_rotation_component( motor_s ,D_ROTA ,start_D ,end_D ,req_D );
	init_rotation_component( motor_s ,Q_ROTA ,start_Q ,end_Q ,req_Q );
	init_blend_data( motor_s );	// Initialise blending data for 'TRANSIT state'

} // initialise_velocity_data
/*****************************************************************************/
static void update_velocity_data( // Update velocity dependent data
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
{
	// Initialise angle variables dependant on spin direction
	if (0 > motor_s.targ_vel)
	{ // Negative spin direction
		motor_s.end_hall = NEGA_LAST_HALL_STATE; // Choose last Hall state of 6-state cycle
		motor_s.speed_inc = -SPEED_INC; // Speed increment when commanded
	} // if (0 > motor_s.targ_vel)
	else
	{ // Positive spin direction
		motor_s.end_hall = POSI_LAST_HALL_STATE; // Choose last Hall state of 6-state cycle
		motor_s.speed_inc = SPEED_INC; // Speed increment when commanded
	} // else !(0 > motor_s.targ_vel)
} // update_velocity_data
/*****************************************************************************/
static void speed_change_reset( // Reset motor data after large speed change
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
{
	motor_s.coef_err = 0; // Clear Extrema Coef. diffusion error
	motor_s.scale_err = 0; // Clear Extrema Scaling diffusion error
	motor_s.Iq_err = 0; // Clear Error diffusion value for measured Iq
	motor_s.prev_Id = 0;	// Initial target 'radial' current value

	motor_s.filt_veloc = (motor_s.est_veloc << VEL_FILT_BITS); // Upscaled Estimated velocity
	motor_s.coef_vel_err = 0; // Velocity filter coefficient diffusion error
	motor_s.scale_vel_err = 0; // Velocity scaling diffusion error

	update_velocity_data( motor_s ); // Update velocity dependent data
} // speed_change_reset
/*****************************************************************************/
static void start_motor_reset( // Reset motor data ready for re-start
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
{
	int phase_cnt; // phase counter
	int state_cnt; // phase counter
	unsigned ts1;	// timestamp


	init_error_data( motor_s.err_data ); // Initialise Error-handling data

	init_pid_data( motor_s ); // Initialise PID data

	// Loop through PWM phases
	for (phase_cnt = 0; phase_cnt < NUM_PWM_PHASES; phase_cnt++)
	{
		motor_s.adc_params.vals[phase_cnt] = 0; // Clear ADC value
	} // for phase_cnt

	// Loop through motor states
	for (state_cnt = 0; state_cnt < NUM_MOTOR_STATES; state_cnt++)
	{
		motor_s.cnts[state_cnt] = 0; // Clear state count
	} // for state_cnt

	motor_s.state = WAIT_START; // Set initial motor-state to 'waiting for command'
	motor_s.iters = 0; // Reset iteration counter
	motor_s.hall_params.hall_val = HALL_NERR_MASK; // Initialise to 'No Errors'
	motor_s.prev_hall = (!HALL_NERR_MASK); // Arbitary value different to above

	motor_s.hall_offset = 0;	// Phase difference between the Hall sensor origin and PWM theta origin
	motor_s.qei_offset = 0;	// Phase difference between the QEI origin and PWM theta origin
	motor_s.hall_found = 0;	// Set flag to Hall origin NOT found
	motor_s.qei_calib = 0;	// Clear QEI calibration flag
	motor_s.fw_on = 0;	// Reset flag to NO Field Weakening

	motor_s.tot_ang = 0;	// Total angle traversed (NB accounts for multiple revolutions)
	motor_s.prev_ang = 0;	// Previous value of total angle
	motor_s.raw_ang = 0;	// Raw QEI total angle value
	motor_s.diff_ang = 0;	// Difference between QEI angles
	motor_s.corr_ang = 0;	// Correction angle (when QEI origin detected)
	motor_s.prev_diff = 0;	// Previous difference between QEI angles
	motor_s.est_theta = 0; // estimated theta value (from QEI data)
	motor_s.set_theta = 0; // Set PWM theta value
	motor_s.open_theta = 0; // Open-loop theta value
	motor_s.open_uq_theta = 0; // Open-loop theta value
	motor_s.foc_theta = 0; // FOC theta value
	motor_s.est_revs = 0; // Estimated No. of revolutions (from QEI data)
	motor_s.prev_revs = 0; // Previous No. of revolutions
	motor_s.filt_period = MILLI_SEC; // Preset QEI period to large value for start-up

	motor_s.trans_cnt = 0; // Counts trans_theta updates

	// Determine spin direction
	if (0 > motor_s.req_veloc)
	{
		motor_s.targ_vel = -START_SPEED; // Start negative target velocity
	} // if (0 > motor_s.req_vel)
	else
	{
		motor_s.targ_vel = START_SPEED; // Start positive target velocity
	} // if (0 > motor_s.req_veloc)

	motor_s.half_veloc = (motor_s.targ_vel >> 1); // Calculate half velocity (used for rounding)
	motor_s.old_veloc = motor_s.targ_vel; // Preset old requested velocity to start-up target velocity

	motor_s.est_veloc = motor_s.stall_speed; // Initial value for Estimated angular velocity (from QEI data)
	motor_s.prev_veloc = motor_s.est_veloc; // Previous measured velocity

	speed_change_reset( motor_s ); // Reset motor data after speed change

	init_velocity_data( motor_s ); // Initialise velocity dependent data

	// Stagger the start of each motor
	motor_s.tymer :> ts1; // Get current time
	ts1 += INIT_SYNC_INCREMENT; // NB Ensure we have a time in the future
	ts1 = ts1 & ~(INIT_SYNC_INCREMENT - 1);	// Align base time reference with PWM_PERIOD boundary

	// Wait until stagger offset for this motor
	motor_s.tymer when timerafter(ts1 + (PWM_STAGGER * motor_s.id)) :> motor_s.restart_time; // Store start-up time
	motor_s.prev_time = motor_s.restart_time; // Initialise previous time_stamp

} // start_motor_reset
/*****************************************************************************/
static void stop_pwm( // Stops motor by switching off PWM
	MOTOR_DATA_TYP &motor_s	// Reference to structure containing motor data
)
{
	int comp_cnt; // rotational-vector component counter


	// Loop through rotational-vector components
	for (comp_cnt = 0; comp_cnt < NUM_ROTA_COMPS; comp_cnt++)
	{
		motor_s.vect_data[comp_cnt].set_V = 0; // Clear current set-Voltage
		motor_s.vect_data[comp_cnt].prev_V = 0; // Clear previous set-Voltage
	} // for comp_cnt

	return;
} // stop_pwm
/*****************************************************************************/
static void init_motor( // initialise data structure for one motor
	MOTOR_DATA_TYP &motor_s, // reference to structure containing motor data
	unsigned motor_id // Unique Motor identifier e.g. 0 or 1
)
{
	int tmp_val; // temporary manipulation value


	// Check consistency of pre-defined QEI values
	tmp_val = (1 << QEI_RES_BITS); // Build No. of QEI points from resolution bits
	assert(QEI_PER_REV == tmp_val); // ERROR: QEI_PER_REV != (1 << QEI_RES_BITS)

	motor_s.id = motor_id; // Store unique Motor identifier e.g. 0 or 1

	motor_s.xscope = 1; 	// Switch on xscope print flag
	motor_s.trans_cycles = 1; // Default number of electrical cycles spent in TRANSIT state
	motor_s.half_qei = (QEI_PER_REV >> 1); // Half No. of QEI points per revolution
	motor_s.stall_speed = (MIN_SPEED >> 3); // Speed below which motor is assumed to have stalled

	// NB Display needs these values before motor is started
	motor_s.est_veloc = 0; // Starting measured velocity is zero
	motor_s.meas_speed = 0; // Starting measured speed is zero

  // Set arbitrary initial motor velocity, while waiting for external request
	if (motor_s.id)
	{
		motor_s.req_veloc = INIT_SPEED; // Motor_1 has Positive spin
	} // if (0 > motor_s.req_vel)
	else
	{
		motor_s.req_veloc = -INIT_SPEED;  // Motor_0 has Negative spin
	} // if (0 > motor_s.req_veloc)

	// Place motor in stationary state
	motor_s.cnts[WAIT_START] = 0; // Clear WAIT_START state counter
	motor_s.state = WAIT_START; // Assign new state

	stop_pwm(motor_s); // Switch off PWM

	start_motor_reset( motor_s ); // Reset motor data ready for re-start
} // init_motor
/*****************************************************************************/
static void init_pwm( // Initialise PWM parameters for one motor
	PWM_COMMS_TYP &pwm_comms_s, // reference to structure containing PWM data
	chanend c_pwm, // PWM channel connecting Client & Server
	unsigned motor_id // Unique Motor identifier e.g. 0 or 1
)
{
	int phase_cnt; // phase counter


	pwm_comms_s.buf = 0; // Current double-buffer in use at shared memory address
	pwm_comms_s.params.id = motor_id; // Unique Motor identifier e.g. 0 or 1

	// Loop through all PWM phases
	for (phase_cnt = 0; phase_cnt < NUM_PWM_PHASES; phase_cnt++)
	{
		pwm_comms_s.params.widths[phase_cnt] = 0;	// Set PWM width to zero
	} // for phase_cnt

	// Receive the address of PWM data structure from the PWM server, in case shared memory is used
	c_pwm :> pwm_comms_s.mem_addr; // Receive shared memory address from PWM server

	return;
} // init_pwm
/*****************************************************************************/
static void error_pwm_values( // Set PWM values to error condition
	unsigned pwm_vals[]	// Array of PWM widths
)
{
	int phase_cnt; // phase counter


	// loop through all PWM phases
	for (phase_cnt = 0; phase_cnt < NUM_PWM_PHASES; phase_cnt++)
	{
		pwm_vals[phase_cnt] = -1; // Set current PWM phase to error value
	} // for phase_cnt
} // error_pwm_values
/*****************************************************************************/
static void filter_current_component( // Filters estimated current component
	ROTA_DATA_TYP &vect_data_s // Reference to structure containing data for one rotational vector component
)
{
	int corr_val; // Correction to previous value
	int filt_val; // Filtered correction value


	// Do Low-pass filter ...

	corr_val = (vect_data_s.inp_I - vect_data_s.est_I); // compute correction to previous filtered value
	corr_val += vect_data_s.rem_I; // Add in error diffusion remainder

	filt_val = (corr_val + ROTA_FILT_HALF) >> ROTA_FILT_RES ; // 1st order filter (uncalibrated value)
	vect_data_s.rem_I = corr_val - (filt_val << ROTA_FILT_RES); // Update remainder

	vect_data_s.est_I += filt_val; // Add filtered difference to previous value
} // filter_current_component
/*****************************************************************************/
static void estimate_Iq_using_transforms( // Calculate Id & Iq currents using transforms. NB Required if requested Id is NON-zero
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
{
	ROTA_VECT_ENUM comp_cnt; // Counts vector components
	int alpha_meas = 0; // Measured currents once transformed to a 2D vector
	int beta_meas = 0;	// Measured currents once transformed to a 2D vector

#pragma xta label "foc_loop_clarke"

	// Convert 3-phase ADC values to 2 component alpha/beta values
	clarke_transform( motor_s.adc_params.vals[ADC_PHASE_A], motor_s.adc_params.vals[ADC_PHASE_B], motor_s.adc_params.vals[ADC_PHASE_C], alpha_meas, beta_meas );

#pragma xta label "foc_loop_park"

	// Estimate coil currents (Id & Iq) using park transform
	// NB Invert alpha & beta here, as Back_EMF is in opposite direction to applied (PWM) voltage

	// Convert 2 component alpha/beta values to Iq, Id and theta values
	park_transform( motor_s.vect_data[D_ROTA].inp_I ,motor_s.vect_data[Q_ROTA].inp_I ,-alpha_meas ,-beta_meas
		,motor_s.set_theta );

	// Loop through rotational-vector components
	for (comp_cnt=0; comp_cnt<NUM_ROTA_COMPS; comp_cnt++)
	{
		filter_current_component( motor_s.vect_data[comp_cnt] );	// Filter this component
	} // for comp_cnt

} // estimate_Iq_using_transforms
/*****************************************************************************/
static unsigned convert_volts_to_pwm_width( // Converted voltages to PWM pulse-widths
	int inp_V  // Input voltage
)
{
	unsigned out_pwm; // output PWM pulse-width


	out_pwm = (inp_V + VOLT_OFFSET) >> VOLT_TO_PWM_BITS; // Convert voltage to PWM value. NB Always +ve

	// Clip PWM value into allowed range
	if (out_pwm > PWM_MAX_LIMIT)
	{
		out_pwm = PWM_MAX_LIMIT; // Limit over-shoot
	} // if (out_pwm > PWM_MAX_LIMIT)
	else
	{
		if (out_pwm < PWM_MIN_LIMIT)
		{
			out_pwm = PWM_MIN_LIMIT; // Limit under-shoot
		} // if (out_pwm < PWM_MIN_LIMIT)
	} // else !(out_pwm > PWM_MAX_LIMIT)

	return out_pwm; // return clipped PWM value
} // convert_volts_to_pwm_width
/*****************************************************************************/
static int smooth_demand_voltage( // Limits large changes in demand voltage
	ROTA_DATA_TYP &vect_data_s // Reference to structure containing data for one rotational vector component
) // Returns smoothed voltage
{
	int set_V = vect_data_s.set_V;  // Input demand voltage (changed for output)


	if (set_V > (vect_data_s.prev_V + HALF_SMOOTH_VOLT))
	{
		set_V = vect_data_s.prev_V + SMOOTH_VOLT_INC; // Allow small increase
	} // if (set_V > vect_data_s.prev_V)
	else
	{
		if (set_V < (vect_data_s.prev_V - HALF_SMOOTH_VOLT))
		{
			set_V = vect_data_s.prev_V - SMOOTH_VOLT_INC; // Allow small decrease
		} // if
	} // else !(set_V > vect_data_s.prev_V)

	vect_data_s.prev_V = set_V; // Store smoothed demand voltage

	return set_V; // Return smoothed value
} // smooth_demand_voltage
/*****************************************************************************/
static void dq_to_pwm ( // Convert Id & Iq input values to 3 PWM output values
	MOTOR_DATA_TYP &motor_s // Reference to structure containing motor data
)
{
	int volts[NUM_PWM_PHASES];	// array of intermediate demand voltages for each phase
	unsigned inp_theta = motor_s.set_theta; // Input demand theta
	int alpha_set = 0, beta_set = 0; // New intermediate demand voltages as a 2D vector
	int phase_cnt; // phase counter


	// Limit large changes in demand voltage
	motor_s.vect_data[D_ROTA].set_V = smooth_demand_voltage( motor_s.vect_data[D_ROTA] );
	motor_s.vect_data[Q_ROTA].set_V = smooth_demand_voltage( motor_s.vect_data[Q_ROTA] );

if (motor_s.xscope) xscope_int( (12+motor_s.id) ,motor_s.vect_data[D_ROTA].set_V ); //MB~
if (motor_s.xscope) xscope_int( (14+motor_s.id) ,motor_s.vect_data[Q_ROTA].set_V ); //MB~

	// Inverse park [D, Q, theta] --> [alpha, beta]
	inverse_park_transform( alpha_set ,beta_set ,motor_s.vect_data[D_ROTA].set_V ,motor_s.vect_data[Q_ROTA].set_V
		,inp_theta );

	// Convert 2 component alpha/beta voltages to 3-phase PWM voltages
	inverse_clarke_transform( volts[PWM_PHASE_A] ,volts[PWM_PHASE_B] ,volts[PWM_PHASE_C] ,alpha_set ,beta_set ); // Correct order


	// Loop through all PWM phases
	for (phase_cnt = 0; phase_cnt < NUM_PWM_PHASES; phase_cnt++)
	{
		// Scale this PWM voltage to 12-bit unsigned for PWM output
		motor_s.pwm_comms.params.widths[phase_cnt] = convert_volts_to_pwm_width( volts[phase_cnt] );
	} // for phase_cnt
} // dq_to_pwm
/*****************************************************************************/
static void calc_open_loop_pwm ( // Calculate open-loop PWM output values to spins magnetic field around (regardless of the encoder)
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
{
	unsigned cur_time; // current time value
	int diff_time; // time since last theta update


	motor_s.tymer :> cur_time; // Get current time
	diff_time = (int)(cur_time - motor_s.prev_time); // Calculate time-difference from previous increment

	// Check if theta needs incrementing
	if (motor_s.open_period < diff_time)
	{ // Update open-loop theta
		motor_s.open_uq_theta += motor_s.open_uq_inc; // Increment demand theta value
		motor_s.open_theta = (motor_s.open_uq_theta + QEI_UQ_HALF) >> QEI_UQ_BITS; // Down-scale to normal QEI resolution
		motor_s.prev_time = cur_time; // Update previous time
	} // if (motor_s.open_period < diff_time)

	// NB QEI_REV_MASK correctly maps -ve values into +ve range 0 <= theta < QEI_PER_REV;
	motor_s.set_theta = motor_s.open_theta & QEI_REV_MASK; // Convert to base-range [0..QEI_REV_MASK]

} // calc_open_loop_pwm
/*****************************************************************************/
static int calc_foc_angle( // Calculate PWM angle for FOC
	MOTOR_DATA_TYP &motor_s, // reference to structure containing motor data
	int qei_theta // QEI angle
) // Returns FOC angle
{
	int foc_angle; 	// FOC angle


	foc_angle = qei_theta + motor_s.qei_offset; // Calculate FOC angle

	return foc_angle; // Return FOC angle
} // calc_foc_angle
/*****************************************************************************/
static int increment_voltage_component( // Returns incremented open-loop voltage for one vector component
	ROTA_DATA_TYP &vect_data_s // Reference to structure containing data for one rotating vector component
)
{
	int upscaled_inc_V = vect_data_s.diff_V; // Up-scaled Voltage increment
	int new_inc_V; // New Voltage increment
	int out_V; // New Output Voltage


	upscaled_inc_V += vect_data_s.rem_V; // Add in remainder for error diffusion
 	new_inc_V = (upscaled_inc_V + BLEND_HALF) >> BLEND_BITS; // Calculate new Voltage increment
	vect_data_s.rem_V = upscaled_inc_V - (new_inc_V << BLEND_BITS);  // Update remainder for error diffusion
	out_V = vect_data_s.trans_V + new_inc_V; // Add new increment to transition voltage

	return out_V; // Return incremented demand voltage
} // increment_voltage_component
/*****************************************************************************/
static void calc_transit_pwm( // Calculate FOC PWM output values
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
{
	unsigned cur_time; // current time value
	int diff_time; // time since last theta update


#pragma xta label "trans_loop_speed_pid"


	motor_s.tymer :> cur_time; // get current time
	diff_time = (int)(cur_time - motor_s.prev_time); // Calculate time-difference from previous increment

	// Check if theta needs incrementing
	if (motor_s.open_period < diff_time)
	{
		motor_s.prev_time = cur_time; // Update previous time

		motor_s.open_uq_theta += motor_s.open_uq_inc; // Increment demand theta value
		motor_s.open_theta = (motor_s.open_uq_theta + QEI_UQ_HALF) >> QEI_UQ_BITS; // Down-scale theta

		motor_s.trans_cnt++; // Increment No of transition cycles

		// Check if time for a Demand voltage increment
		if (motor_s.trans_cycles == motor_s.trans_cnt)
		{
			motor_s.trans_cnt = 0; // Reset trans_theta update counter
			motor_s.blend_weight += motor_s.blend_inc; // Increment blending weight

			// Smoothly change Demand voltage from open-loop to closed-loop values
			motor_s.vect_data[D_ROTA].trans_V = increment_voltage_component( motor_s.vect_data[D_ROTA] );
			motor_s.vect_data[Q_ROTA].trans_V = increment_voltage_component( motor_s.vect_data[Q_ROTA] );
		} // if (motor_s.trans_cycles == motor_s.trans_cnt)
	} // if (motor_s.open_period < diff_time)

	// WARNING: Do NOT allow  motor_s.foc_theta or motor_s.open_theta to wrap otherwise weighting will NOT work
	motor_s.foc_theta = calc_foc_angle( motor_s ,motor_s.tot_ang ); // Calculate FOC-angle, from QEI-angle

	// Calculate weighted difference (between old and new theta values)
	motor_s.set_theta = (motor_s.blend_weight * (motor_s.foc_theta - motor_s.open_theta) + BLEND_HALF) >> BLEND_BITS;

	motor_s.set_theta += motor_s.open_theta; // Add in Old value (Starting Value)

	motor_s.set_theta &= QEI_REV_MASK; // Convert to base-range [0..QEI_REV_MASK]

	// Assign 'set' Voltages
	motor_s.vect_data[D_ROTA].set_V = motor_s.vect_data[D_ROTA].trans_V;
	motor_s.vect_data[Q_ROTA].set_V = motor_s.vect_data[Q_ROTA].trans_V;
} // calc_transit_pwm
/*****************************************************************************/
static int update_target_velocity( // If necessary, update target velocity
	MOTOR_DATA_TYP &motor_s // Reference to structure containing motor data
) // Returns updated target velocity
/* This routine smoothes out changes in the requested velocity,
 * by allowing the target velocity to move towards the requested velocity, incrementally.
 */
{
	int out_veloc = motor_s.targ_vel; // preset to current target velocity


	// Check if target velocity needs updating
	if (out_veloc < motor_s.req_veloc)
	{ // Target velocity too small
		out_veloc++; // Increment target velocity
		motor_s.half_veloc = (out_veloc >> 1); // Update half pf target-velocity (used in rounding)

		// Check for change in spin direction
		if (1 == out_veloc)
		{
			update_velocity_data( motor_s ); // Update velocity dependent data
		} // if
	} // if (out_veloc < motor_s.req_veloc)
	else
	{
		if (out_veloc > motor_s.req_veloc)
		{ // Target velocity too large
			out_veloc--; // Decrement target velocity
			motor_s.half_veloc = (out_veloc >> 1); // Update half pf target-velocity (used in rounding)

			// Check for change in spin direction
			if ((-1) == out_veloc)
			{
				update_velocity_data( motor_s ); // Update velocity dependent data
			} // if (0 > (old_veloc * out_veloc))
		} // if (out_veloc > motor_s.req_veloc)
	} // else (out_veloc < motor_s.req_veloc)

	return out_veloc; // Return updated output velocity
} // update_target_velocity
/*****************************************************************************/
static void update_foc_voltage( // Update FOC PWM Voltage (Pulse Width) output values
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
{
	int targ_Id;	// target 'radial' current value
	int targ_Iq;	// target 'tangential' current value
	int abs_Id; // magnitude if target Id value;


#pragma xta label "foc_loop_speed_pid"

	// Applying Speed PID.

	// Check if PID's need presetting
	if (motor_s.pid_preset)
	{ // Preset the Velocity PID
		preset_pid( motor_s.id ,motor_s.pid_regs[SPEED_PID] ,motor_s.pid_consts[SPEED_PID] ,motor_s.old_veloc ,motor_s.targ_vel ,motor_s.est_veloc );
	}; // if (motor_s.pid_preset)

if (motor_s.xscope) xscope_int( (10+motor_s.id) ,motor_s.targ_vel ); //MB~

	// Get the New 'set' Velocity
//CW~ motor_s.pid_veloc = get_cw_pid_regulator_correction( motor_s.id ,SPEED_PID ,motor_s.pid_regs[SPEED_PID] ,motor_s.pid_consts[SPEED_PID] ,motor_s.targ_vel ,motor_s.est_veloc ,abs(motor_s.diff_ang) );
	motor_s.pid_veloc = get_mb_pid_regulator_correction( motor_s.id ,SPEED_PID ,motor_s.pid_regs[SPEED_PID] ,motor_s.pid_consts[SPEED_PID] ,motor_s.targ_vel ,motor_s.est_veloc ,abs(motor_s.diff_ang) );
if (motor_s.xscope) xscope_int( 16 ,(motor_s.targ_vel - motor_s.est_veloc) ); //MB~
if (motor_s.xscope) xscope_int( 17 ,motor_s.pid_regs[SPEED_PID].sum_err ); //MB~

	// Convert 'set' Velocity to requested Vq voltage
	motor_s.vect_data[Q_ROTA].req_closed_V = ((S2V_MUX * motor_s.pid_veloc) + HALF_S2V) >> S2V_BITS;

	// Check for Negative spin direction
	if (0 > motor_s.targ_vel)
	{ // Reverse sense of req_Vq
		motor_s.vect_data[Q_ROTA].req_closed_V = -motor_s.vect_data[Q_ROTA].req_closed_V;
	} // if (0 > motor_s.targ_vel)

#pragma xta label "foc_loop_id_iq_pid"

	// WARNING: Dividing by a larger amount, may switch the sign of the PID error, and cause instability
	targ_Iq = ((V2I_MUX * motor_s.vect_data[Q_ROTA].req_closed_V) + HALF_V2I) >> V2I_BITS;

	/* Here we would like to set targ_Id = 0, for max. efficiency.
	 * However, some motors can NOT reach 4000 RPM, no matter how much Vq is increased.
   * Therefore need to adjust targ_Id slowly towards targ_Id = sign(req_veloc) * est_Iq;
	 * NB Future work:- Add new motor-state where targ_Id = sign(req_veloc) * est_Iq;
	 * req_V is much lower for this state, ~920. Therefore need smooth tranasition
	 * Also, each time targ_Id is changed, Iq takes about 1 second to stabilise
   */

	targ_Id = 0; // Preset target Id value to 'NO field-weakening'

  // Check if field-weakening required
	if (targ_Iq > IQ_LIM)
	{ // Apply field weakening

	  // Check for over-large target Iq
		if (targ_Iq > (IQ_LIM << 1))
		{ // Over-large
			targ_Iq = (targ_Iq >> 1); // Halve Iq value
			abs_Id = (targ_Iq + IQ_ID_HALF) >> IQ_ID_BITS; // Calculate new absolute Id value, NB divide by IQ_ID_RATIO
		} // if (targ_Iq > (IQ_LIM << 1))
		else
		{ // Just over limit
			abs_Id = (targ_Iq - IQ_LIM + IQ_ID_HALF) >> IQ_ID_BITS; // Calculate new absolute Id value, NB divide by IQ_ID_RATIO
			targ_Iq = IQ_LIM; // Limit target Iq value
		} // else !(targ_Iq > (IQ_LIM << 1))

		targ_Id = abs(motor_s.prev_Id); // Preset to magnitude of previous value

		// Add a bit of hysterisis.
		if (targ_Id > (abs_Id + 1))
		{ // new Id is less than hysterisis margin
			targ_Id = abs_Id + 1; // Decrement targ_Id
		} // if (targ_Id > (abs_Id + 1))
		else
		{
			if (targ_Id < (abs_Id - 1))
			{  // new Id is larger than hysterisis margin
				 targ_Id = abs_Id - 1; //Increment targ_Id
			} // if (targ_Id < (abs_Id - 1))
		} // else !(targ_Id > (abs_Id + 1))

		// Check spin direction
		if (0 > motor_s.targ_vel)
		{ // Negative spin direction
			targ_Id = -targ_Id; // targ_Id must be -ve for -ve spin
		} // if (0 > motor_s.targ_vel)

		// Check if Field-Weakening Applied
		if (0 != targ_Id)
		{
			// Check if first time Field-Weakening Applied
			if (0 == motor_s.fw_on)
			{
				acquire_lock();
				printint(motor_s.id); printstrln(": FW Required");
				release_lock();

				motor_s.fw_on = 1;	// Set flag to Field Weakening On
			} // if (0 == motor_s.fw_on)
		} // if (0 != targ_Id)
	} // if ((targ_Iq > IQ_LIM)

	motor_s.prev_Id = targ_Id; // Update previous target Id value

//MB~ targ_Iq = 20; // CW~  Iq PID tuning
if (motor_s.xscope) xscope_int( (6+motor_s.id) ,targ_Id ); // MB~
if (motor_s.xscope) xscope_int( (8+motor_s.id) ,targ_Iq ); // MB~
	// Apply PID control to Iq and Id

	// Check if PID's need presetting
	if (motor_s.pid_preset)
	{ // Preset the Current PID's
		preset_pid( motor_s.id ,motor_s.pid_regs[ID_PID] ,motor_s.pid_consts[ID_PID] ,motor_s.vect_data[D_ROTA].end_open_V ,targ_Id ,motor_s.vect_data[D_ROTA].est_I );
		preset_pid( motor_s.id ,motor_s.pid_regs[IQ_PID] ,motor_s.pid_consts[IQ_PID] ,motor_s.vect_data[Q_ROTA].end_open_V ,targ_Iq ,motor_s.vect_data[Q_ROTA].est_I );
	}; // if (motor_s.pid_preset)

	// Get the New 'set' Current's
	motor_s.pid_Id = get_mb_pid_regulator_correction( motor_s.id ,ID_PID ,motor_s.pid_regs[ID_PID] ,motor_s.pid_consts[ID_PID] ,targ_Id ,motor_s.vect_data[D_ROTA].est_I ,abs(motor_s.diff_ang) );
	motor_s.pid_Iq = get_mb_pid_regulator_correction( motor_s.id ,IQ_PID ,motor_s.pid_regs[IQ_PID] ,motor_s.pid_consts[IQ_PID] ,targ_Iq ,motor_s.vect_data[Q_ROTA].est_I ,abs(motor_s.diff_ang) );
//CW~ motor_s.pid_Iq = get_cw_pid_regulator_correction( motor_s.id ,IQ_PID ,motor_s.pid_regs[IQ_PID] ,motor_s.pid_consts[IQ_PID] ,targ_Iq ,motor_s.vect_data[Q_ROTA].est_I ,abs(motor_s.diff_ang) );
if (motor_s.xscope) xscope_int( 18 ,(targ_Iq - motor_s.vect_data[Q_ROTA].est_I) ); //MB~
if (motor_s.xscope) xscope_int( 19 ,motor_s.pid_regs[IQ_PID].sum_err ); //MB~

	// Convert 'set' Currents to set PWM voltages
	motor_s.vect_data[D_ROTA].set_V  = motor_s.pid_Id;
	motor_s.vect_data[Q_ROTA].set_V = motor_s.pid_Iq;

	motor_s.pid_preset = 0; // Clear 'Preset PID' flag

} // update_foc_voltage
/*****************************************************************************/
static int update_foc_angle( // Update FOC PWM angular postion
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
) // Returns PWM angular position
{
	int out_theta;	// PWM theta value


	// Update 'demand' theta value for next dq_to_pwm iteration from QEI-angle
	out_theta = calc_foc_angle( motor_s ,motor_s.est_theta ); // get next angular position
	out_theta &= QEI_REV_MASK; // Convert to base-range [0..QEI_REV_MASK]

	return out_theta;  // Return new PWM angular position
} // update_foc_angle
/*****************************************************************************/
static void calc_foc_pwm( // Calculate FOC PWM output values
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
{
	motor_s.old_veloc =  motor_s.targ_vel; // Store previous target velocity

	motor_s.targ_vel = update_target_velocity( motor_s );	// If necessary, update target veloccity

	update_foc_voltage( motor_s ); // Update FOC PWM Voltage (Pulse Width) output values

	motor_s.set_theta = update_foc_angle( motor_s ); // Update FOC PWM angular postion

} // calc_foc_pwm
/*****************************************************************************/
static MOTOR_STATE_ENUM check_spin_direction( // Check if motor is spinning in wrong direction
	MOTOR_DATA_TYP &motor_s // Reference to structure containing motor data
) // Returns WAIT_STOP state if wrong-spin detected
{
	int wrong_spin = 0; // Preset flag to NOT wrong spin direction
	MOTOR_STATE_ENUM new_state = motor_s.state; // Preset new state to old state


	// check for correct spin direction
	if (0 > motor_s.targ_vel)
	{ // Should be spinning in negative direction
		if (MIN_SPEED < motor_s.est_veloc)
		{	// Spinning in wrong direction
			wrong_spin = 1;  // Set flag to wrong spin direction
		} // if (motor_s.stall_speed < motor_s.est_veloc)
	} // if (0 > motor_s.targ_vel)
	else
	{ // Should be spinning in positive direction
		if (MIN_SPEED < -motor_s.est_veloc)
		{	// Spinning in wrong direction
			wrong_spin = 1;  // Set flag to wrong spin direction
		} // if (motor_s.stall_speed < -motor_s.est_veloc)
	} // else !(0 > motor_s.targ_vel)

	// check if wrong spin detected
	if (1 == wrong_spin)
	{
		unsigned cur_time; // Current time
		unsigned dif_time; // Time since last re-start


		motor_s.tymer :> cur_time; // Get current time

		// Calculate elapsed-time since previous restart
		dif_time = cur_time - motor_s.restart_time; // NB unsigned handles wrap-around

		motor_s.err_data.err_flgs |= (1 << DIRECTION_ERR);
		motor_s.err_data.line[DIRECTION_ERR] = __LINE__;
		motor_s.cnts[WAIT_STOP] = 0; // Initialise stop-state counter

		// Check if wrong-spin occured shortly after start-up
		if (MILLI_400_SECS < dif_time)
		{ // Detected after start-up state
			acquire_lock();
			printint(motor_s.id); printstr(": WARNING: Wrong FOC Spin.");
			printstr(" Vel="); printintln(motor_s.est_veloc);
			release_lock();
		} // if (MILLI_400_SECS < dif_time)
		else
		{ // Detected during start-up state
			acquire_lock();
			printint(motor_s.id); printstr(": Wrong Start-Up Spin.");
			printstr(" Vel="); printintln(motor_s.est_veloc);
			release_lock();
		} // else !(MILLI_400_SECS < dif_time)

		new_state = WAIT_STOP; // Switch to stop state
	} // if (1 == wrong_spin)

	return new_state; // return new motor state
} // check_spin_direction
/*****************************************************************************/
static MOTOR_STATE_ENUM check_for_stall( // Check motor if motor has stalled
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
) // Returns WAIT_STOP state if motor has stalled
{
	MOTOR_STATE_ENUM new_state = motor_s.state; // Preset new state to old state


	// Check if still stalled
	if (motor_s.meas_speed < motor_s.stall_speed)
	{
		// Check if too many stalled states
		if (motor_s.cnts[STALL] > STALL_TRIP_COUNT)
		{
			unsigned cur_time; // Current time
			unsigned dif_time; // Time since last re-start


			motor_s.err_data.err_flgs |= (1 << STALL);
			motor_s.err_data.line[STALLED_ERR] = __LINE__;
			motor_s.cnts[WAIT_START] = 0; // Initialise stop-state counter

			motor_s.tymer :> cur_time; // Get current time

			// Calculate elapsed-time since previous restart
			dif_time = cur_time - motor_s.restart_time; // NB unsigned handles wrap-around

			// Check if stall occured shortly after start-up
			if (MILLI_400_SECS < dif_time)
			{ // Detected after start-up state
				acquire_lock(); printint(motor_s.id); printstr(": WARNING FOC Stalled"); release_lock();
			} // if (MILLI_400_SECS < dif_time)
			else
			{ // Detected during start-up state
				acquire_lock(); printint(motor_s.id); printstr(": Start-up Stall"); release_lock();
			} // else !(MILLI_400_SECS < dif_time)

			new_state = WAIT_START; // Switch to stop state
		} // if (motor_s.cnts[STALL] > STALL_TRIP_COUNT)
	} // if (motor_s.meas_speed < motor_s.stall_speed)
	else
	{ // No longer stalled
		motor_s.cnts[FOC] = 0; // Initialise FOC-state counter

		motor_s.fw_on = 0;	// Reset flag to NO Field Weakening
		new_state = FOC; // Switch to main FOC state
	} // else !(motor_s.meas_speed < motor_s.stall_speed)

	return new_state; // return new motor state
} // check_for_stall
/*****************************************S************************************/
static void update_motor_state( // Update state of motor based on motor sensor data
	MOTOR_DATA_TYP &motor_s // reference to structure containing motor data
)
/* This routine is inplemented as a Finite-State-Machine (FSM) with NUM_MOTOR_STATES different states
 * See inner_loop.h for an explanation of the different states
 */
{
if (motor_s.xscope) xscope_int( motor_s.id ,motor_s.vect_data[D_ROTA].est_I ); //MB~
if (motor_s.xscope) xscope_int( (2+motor_s.id) ,motor_s.vect_data[Q_ROTA].est_I ); //MB~
if (motor_s.xscope) xscope_int( (4+motor_s.id) ,motor_s.est_veloc ); // MB~

	// Determine motor state
	switch( motor_s.state )
	{
		case WAIT_START : // Wait for non-zero requested speed
		{
			stop_pwm( motor_s ); // Switch off PWM

			// Check if valid start speed detected
			if (MIN_SPEED <= abs(motor_s.req_veloc))
			{
				start_motor_reset( motor_s ); // start motor
				motor_s.state = ALIGN;
			} // if
		} break; // case WAIT_START

		case ALIGN: // Align rotor magnets opposite motor coils
		{
			unsigned ts1;	// timestamp
			unsigned diff_time;	// time difference

			motor_s.tymer :> ts1; // Get current time
			diff_time = ts1 - motor_s.prev_time; // Get elapsed time since motor started

			// Check if alignment nearly complete
			if (ALIGN_PERIOD < diff_time)
			{
				// Check for zero-crossing of angular velocity (in correct direction)
				if (((0 < motor_s.targ_vel) && (0 > motor_s.prev_veloc) && (0 <= motor_s.est_veloc))
					|| ((0 > motor_s.targ_vel) && (0 < motor_s.prev_veloc) && (0 >= motor_s.est_veloc)))
				{
					motor_s.prev_time = ts1; // Store time-stamp

					motor_s.state = SEARCH;
				} // if ...
			} // if (ALIGN_PERIOD < diff_time)
		} break; // case ALIGN

		case SEARCH : // Start motor open-loop
 			calc_open_loop_pwm( motor_s ); // Turn motor by incrementing open-loop theta

			// Check if end of SEARCH state
			if (motor_s.search_theta == abs(motor_s.open_theta))
			{ /* Calculate QEI offset
				 * In FOC state, theta will be based on angle returned from QEI sensor.
         * So recalibrate, to create smooth transition between SEARCH and FOC states.
				 */
				motor_s.qei_offset = (motor_s.open_theta - motor_s.tot_ang); // Difference betweene Open-loop and QEI angle
				motor_s.state = TRANSIT;
				motor_s.state = check_spin_direction( motor_s ); // Check if motor is spinning in wrong direction
			} // if (QEI_PER_PAIR == abs(motor_s.open_theta))
		break; // case SEARCH

		case TRANSIT : // Transit between open-loop and FOC
 			calc_transit_pwm( motor_s ); // Calculate both open-loop and closed-loop theta values

			motor_s.state = check_spin_direction( motor_s ); // Check if motor is spinning in wrong direction

			// Check if start-up problem detected
			if (WAIT_STOP != motor_s.state)
			{ // start-up OK
				// Check if end of TRANSIT state
				if (motor_s.trans_theta == abs(motor_s.open_theta))
				{
					motor_s.vect_data[D_ROTA].start_open_V = motor_s.vect_data[D_ROTA].end_open_V; // NB Correct for any rounding inaccuracy from TRANSIT state
					motor_s.vect_data[Q_ROTA].start_open_V = motor_s.vect_data[Q_ROTA].end_open_V; // NB Correct for any rounding inaccuracy from TRANSIT state
					motor_s.fw_on = 0;	// Reset flag to NO Field Weakening
					motor_s.state = FOC;
				} // if ((QEI_PER_PAIR << 1) == abs(motor_s.open_theta))
			} // if (WAIT_STOP != motor_s.state)
		break; // case TRANSIT

		case FOC : // Normal FOC state
			// Check if QEI data changed since previous update
			if (motor_s.diff_ang != 0)
			{
				calc_foc_pwm( motor_s ); // Do an FOC iteration
			} // if (motor_s.diff_ang != 0)

			motor_s.state = check_spin_direction( motor_s ); // Check if motor is spinning in wrong direction

			// Check if spin problem detected
			if (WAIT_STOP != motor_s.state)
			{
				// Check if motor stalled
				if (motor_s.meas_speed < motor_s.stall_speed)
				{ // Motor stalled
					motor_s.cnts[STALL] = 0; // Initialise stall-state counter

					motor_s.state = STALL; // Switch to stall state
				} // if (motor_s.meas_speed < motor_s.stall_speed)
			} // if (WAIT_STOP != motor_s.state)
		break; // case FOC

		case STALL : // state where motor stalled
			calc_foc_pwm( motor_s ); // Do an FOC iteration

			motor_s.state = check_for_stall( motor_s ); // NB Returns state=FOC, if motor no longer stalled
		break; // case STALL

		case WAIT_STOP : // State where Coil current switched off
			motor_s.targ_vel = 0; // Clear target velocity

			calc_foc_pwm( motor_s ); // Do an FOC iteration

			stop_pwm( motor_s ); // Switch off PWM

			// Check if still stalled
			if (motor_s.meas_speed < motor_s.stall_speed)
			{
				motor_s.state = WAIT_START; // Switch to stop state
			} // if (motor_s.meas_speed < motor_s.stall_speed)
		break; // case WAIT_STOP

		case POWER_OFF : // Error state where motor stopped
			acquire_lock(); printint(motor_s.id); printstrln(": POWER_OFF"); release_lock(); //MB~

			// Absorbing state. Nothing to do
		break; // case POWER_OFF

    default: // Unsupported
			assert(0 == 1); // Motor state not supported
    break;
	} // switch( motor_s.state )

	motor_s.cnts[motor_s.state]++; // Update counter for new motor state

	return;
} // update_motor_state
/*****************************************************************************/
void wait_for_servers_to_start( // Wait for other servers to initialise
	MOTOR_DATA_TYP &motor_s, // Structure containing motor data
	chanend c_wd, // Channel for communication with WatchDog server
	chanend c_pwm, // Channel for communication with PWM server
	streaming chanend c_hall, // Channel for communication with Hall server
	streaming chanend c_qei,  // Channel for communication with QEI server
	streaming chanend c_adc_cntrl // Channel for communication with ADC server
)
#define NUM_INIT_SERVERS 4 // WARNING: edit this line to indicate No of servers to wait on
{
	unsigned ts1;	// timestamp
	int wait_cnt = NUM_INIT_SERVERS; // Set number of un-initialised servers
	unsigned cmd; // Command from Server


	c_wd <: WD_CMD_INIT;	// Signal WatchDog to Initialise ...

	// Loop until all servers have started
	while(0 < wait_cnt)
	{
		// Wait for ANY channel command
		select {
			case c_hall :> cmd : // Hall server
			{
				assert(HALL_CMD_ACK == cmd); // ERROR: Hall server did NOT send acknowledge signal
				wait_cnt--; // Decrement number of un-initialised servers
			} // case	c_hall
			break;

			case c_qei :> cmd : // QEI server
			{
				assert(QEI_CMD_ACK == cmd); // ERROR: QEI server did NOT send acknowledge signal
				wait_cnt--; // Decrement number of un-initialised servers
			} // case	c_qei
			break;

			case c_adc_cntrl :> cmd : // ADC server
			{
				assert(ADC_CMD_ACK == cmd); // ERROR: ADC server did NOT send acknowledge signal
				wait_cnt--; // Decrement number of un-initialised servers
			} // case	c_adc_cntrl
			break;

			case c_wd :> cmd : // WatchDog server
			{
				assert(WD_CMD_ACK == cmd); // ERROR: WatchDog server did NOT send acknowledge signal
				wait_cnt--; // Decrement number of un-initialised servers
			} // case	c_pwm
			break;

			default :
				acquire_lock(); printint(motor_s.id);	release_lock();
				motor_s.tymer :> ts1;
				motor_s.tymer when timerafter(ts1 + MILLI_SEC) :> void;
			break; // default
		} // select
	} // while(0 < run_cnt)

	acquire_lock(); printstrln("");	release_lock();

} // wait_for_servers_to_start
/*****************************************************************************/
static void find_hall_origin( // Test Hall-state for origin (NB currently un-used)
	MOTOR_DATA_TYP &motor_s // Reference to structure containing motor data
) // Returns new motor-state
/* The input pins from the Hall port hold the following data
 * Bit_3: Over-current flag (NB Value zero is over-current)
 * Bit_2: Hall Sensor Phase_C
 * Bit_1: Hall Sensor Phase_B
 * Bit_0: Hall Sensor Phase_A
 *
 * The Sensor bits are toggled every 180 degrees.
 * Each phase is separated by 120 degrees.
 * WARNING: By Convention Phase_A is the MS-bit.
 * However on the XMOS Motor boards, Phase_A is the LS-bit
 * This gives the following valid bit patterns for [CBA]
 *
 *      <-------- Positive Spin <--------
 * (011)  001  101  100  110  010  011  (001)   [CBA]
 *      --------> Negative Spin -------->
 *
 * WARNING: By Convention Phase_A leads Phase B for a positive spin.
 * However, each motor manufacturer may use their own definition for spin direction.
 * So key Hall-states are implemented as defines e.g. FIRST_HALL and LAST_HALL
 *
 * For the purposes of this algorithm, the angular position origin is defined as
 * the transition from the last-state to the first-state.
 */
{
	unsigned hall_inp = (motor_s.hall_params.hall_val & HALL_PHASE_MASK); // Mask out 3 Hall Sensor Phase Bits


	// Check for change in Hall state
	if (motor_s.prev_hall != hall_inp)
	{ //  Hall state changed
		// Check for 1st Hall state, as we only do this check once a revolution
		if (hall_inp == FIRST_HALL_STATE)
		{ // 1st hall state
			// Check for correct spin direction
			if (motor_s.prev_hall == motor_s.end_hall)
			{ // Spinning in correct direction

				// Check if the angular origin has been found, AND, we have done more than one revolution
				if (1 < abs(motor_s.est_revs))
				{
					/* Calculate the offset between arbitary PWM set_theta and actual measured theta,
					 * NB There are multiple values of set_theta that can be used for each meas_theta,
           * depending on the number of pole pairs. E.g. [0, 256, 512, 768] are equivalent.
					 */
					motor_s.hall_offset = motor_s.set_theta;
					motor_s.hall_found = 1; // Set flag indicating Hall origin located
				} // if (0 < motor_s.est_revs)
			} // if (motor_s.prev_hall == motor_s.end_hall)
		} // if (hall_inp == FIRST_HALL_STATE)

		motor_s.prev_hall = hall_inp; // Store hall state for next iteration
	} // if (motor_s.prev_hall != hall_inp)

} // find_hall_origin
/*****************************************************************************/
static void correct_qei_origin( // If necessary, apply a correction to the QEI offset
	MOTOR_DATA_TYP &motor_s // Reference to structure containing motor data
) // Returns new motor-state
/* When the QEI origin is found, the QEI angle will be reset to zero.
 * This may happen before (1), or after (2), the QEI offset has been calculated.
 * (1) If the origin is found before the QEI offset is calculated:
 *   then the QEI offset is already correct, and the 1st correction received will be
 *   approximately zero, leaving the QEI offset unchanged.
 * (2) If the origin is found after the QEI offset has been calculated:
 *   then the the 1st correction received will be NON-zero, and will correct the QEI offset.
 */
{
	// Check if QEI has been calibrated
	if (0 == motor_s.qei_calib)
	{ // NOT calibrated

 		// Check for valid correction
		if (motor_s.qei_params.orig_corr)
		{ // Correct QEI offset, now QEI theta has done origin reset

			// Check if QEI offset has been calculated (at end of SEARCH state)
			if (SEARCH < motor_s.state)
			{ // Apply correction to offset
				motor_s.qei_offset += motor_s.qei_params.corr_ang; // Add upscaled correction
				motor_s.qei_calib = 1; // Set QEI calibrated flag

				motor_s.raw_ang += motor_s.qei_params.corr_ang; // Add incremental correction to previous raw total angle
			} // if (SEARCH < motor_s.state)
			else
			{ // QEI Offset NOT yet calculated. Update correction to total-angle
				motor_s.corr_ang += motor_s.qei_params.corr_ang; // Update total correction
				motor_s.qei_params.tot_ang += motor_s.corr_ang ; // Add total correction to total-angle
			} // if (SEARCH < motor_s.state)

			motor_s.qei_params.corr_ang = 0; // Clear correction value
			motor_s.qei_params.orig_corr = 0; // Reset flag to QEI correction NOT available
		} // if (motor_s.qei_params.orig_corr)
	} // if (0 == motor_s.qei_calib)

} // correct_qei_origin
/*****************************************************************************/
static unsigned filter_period( // Smoothes QEI period using low-pass filter
	MOTOR_DATA_TYP &motor_s, // Reference to structure containing motor data
	unsigned inp_period // Input QEI period: ticks per QEI position (in Reference Frequency Cycles)
) // Returns filtered output value
/* This is a 1st order IIR filter, it is configured as a low-pass filter,
 * Error diffusion is used to keep control of systematic quantisation errors.
 */
{
	int diff_val; // Difference between input and filtered output
	int increment; // new increment to filtered output value
	unsigned out_period = inp_period; // preset output to input value


	// Check for sensible value
	if (inp_period < MAX_PERIOD)
	{ //
		// Form difference with previous filter output
		diff_val = inp_period - motor_s.filt_period;

		// Multiply difference by filter coefficient (alpha)
		diff_val += motor_s.period_coef_err; // Add in diffusion error;
		increment = (diff_val + PERIOD_HALF_COEF) >> PERIOD_COEF_BITS; // Multiply by filter coef (with rounding)
		motor_s.period_coef_err = diff_val - (increment << PERIOD_COEF_BITS); // Evaluate new quantisation error value

		motor_s.filt_period += increment; // Form new filtered value
		out_period = motor_s.filt_period; // Output new filtered value
	} // if (inp_period < MAX_PERIOD)

	return out_period; // return filtered output value
} // filter_period
/*****************************************************************************/
static int filter_velocity( // Smooths velocity estimate using low-pass filter
	MOTOR_DATA_TYP &motor_s, // Reference to structure containing motor data
	int meas_veloc // Angular velocity of motor measured in Ticks/angle_position
) // Returns filtered output value
/* This is a 1st order IIR filter, it is configured as a low-pass filter,
 * The input velocity value is up-scaled, to allow integer arithmetic to be used.
 * The output mean value is down-scaled by the same amount.
 * Error diffusion is used to keep control of systematic quantisation errors.
 */
{
	int scaled_inp = (meas_veloc << VEL_FILT_BITS); // Upscaled QEI input value
	int diff_val; // Difference between input and filtered output
	int increment; // new increment to filtered output value
	int out_veloc = meas_veloc; // preset output to input value


	// Check for sensible value
	if ((abs(meas_veloc) > motor_s.stall_speed)	&& (abs(meas_veloc) < SAFE_MAX_SPEED))
	{
		// Form difference with previous filter output
		diff_val = scaled_inp - motor_s.filt_veloc;

		// Multiply difference by filter coefficient (alpha)
		diff_val += motor_s.coef_vel_err; // Add in diffusion error;
		increment = (diff_val + VEL_HALF_COEF) >> VEL_COEF_BITS ; // Multiply by filter coef (with rounding)
		motor_s.coef_vel_err = diff_val - (increment << VEL_COEF_BITS); // Evaluate new quantisation error value

		motor_s.filt_veloc += increment; // Update (up-scaled) filtered output value

		// Update mean value by down-scaling filtered output value
		motor_s.filt_veloc += motor_s.scale_vel_err; // Add in diffusion error;
		out_veloc = (motor_s.filt_veloc + VEL_FILT_HALF) >> VEL_FILT_BITS; // Down-scale
		motor_s.scale_vel_err = motor_s.filt_veloc - (out_veloc << VEL_FILT_BITS); // Evaluate new remainder value
	} // if ((abs(meas_veloc) > motor_s.stall_speed)	&& (abs(meas_veloc) < SAFE_MAX_SPEED))

	return out_veloc; // return filtered output value
} // filter_velocity
/*****************************************************************************/
static int get_velocity( // Returns updated velocity estimate from time period. (Angular_speed in RPM)
	MOTOR_DATA_TYP &motor_s, // Reference to structure containing motor data
	int ang_inc, // Absolute angle increment
	unsigned inp_period // QEI period: input (unsigned) ticks per QEI position (in Reference Frequency Cycles)
)
{
	int meas_veloc; // Measured angular velocity
	int out_veloc; // Output (possibly filtered) angular velocity
	int int_period = (int)inp_period; // Convert to an integer to make arithmetic work!-(
	int ticks_rpm; // Ticks * Revolutions Per Min


	ticks_rpm = (int)TICKS_PER_MIN_PER_QEI + (int_period >> 1); // NB Intermediate value

	// Account for sign: to get correct rounding
	if (0 < ang_inc)
	{
		ticks_rpm = motor_s.veloc_calc_err + ticks_rpm; // Add in diffusion error
	} // if (0 < ang_inc)
	else
	{
		ticks_rpm = motor_s.veloc_calc_err - ticks_rpm; // Add in diffusion error
	} // else !(0 < ang_inc)

	assert(int_period != 0); // ERROR: Division by zero trap

	meas_veloc = (ticks_rpm / int_period); // Evaluate (signed) angular_velocity of motor in RPM
	motor_s.veloc_calc_err = ticks_rpm - (meas_veloc * int_period); // Evaluate new remainder value

	// Check if filter selected
	if (QEI_FILTER)
	{
		out_veloc = filter_velocity( motor_s ,meas_veloc ); // Use smoothed velocity estimate
	} // if (QEI_FILTER)
	else
	{
		out_veloc = meas_veloc; // Use unfiltered  velocity estimate
	} // else !(QEI_FILTER)

	return out_veloc;
}	// get_velocity
/*****************************************************************************/
static void get_qei_data( // Get raw QEI data, and compute QEI parameters (E.g. Velocity estimate)
	MOTOR_DATA_TYP &motor_s, // Reference to structure containing motor data
	streaming chanend c_qei // QEI channel
)
{
	int diff_ang; // Difference angle
	int rev_bits; // Bits of total angle count used for revolution count
	signed char diff_revs; // Difference in LS bits of revolution counter
	unsigned qei_period; // QEI period: input (unsigned) ticks per QEI position (in Reference Frequency Cycles)
	unsigned cur_time; // Current time
	unsigned dif_time; // Time since last re-start


	foc_qei_get_parameters( motor_s.qei_params ,c_qei ); // Get New QEI data

	correct_qei_origin( motor_s );	// If necessary. correct QEI angle

	// Calculate elasped angle since previous update
	motor_s.diff_ang = motor_s.qei_params.tot_ang - motor_s.raw_ang;

	motor_s.tymer :> cur_time; // Get current time

	// Calculate elapsed-time since previous restart
	dif_time = cur_time - motor_s.restart_time; // NB unsigned handles wrap-around

	// Check if start-up
	if (MILLI_400_SECS < dif_time)
	{ // After start-up

		// Check if elapsed angle too large
		if (abs(motor_s.diff_ang) > 10)
		{ // Elapsed angle too large
			acquire_lock(); printstr("WARNING: Bad QEI Data, Angle Increment="); printintln(motor_s.diff_ang); release_lock(); //MB~
		} // if (abs(tmp_diff) > 10)
	} // if (MILLI_400_SECS < dif_time)

	motor_s.raw_ang =  motor_s.qei_params.tot_ang; // Store raw angle velue

	// Check for changed data
	if (motor_s.qei_params.phase_period > 0)
	{ // Changed Data

		// The theta value should be in the range:  -180 <= theta < 180 degrees ...
		motor_s.tot_ang = motor_s.qei_params.tot_ang;	// Calculate total angle traversed

		rev_bits = (motor_s.tot_ang + motor_s.half_qei) >> QEI_RES_BITS; // Get revolution bits
		motor_s.est_theta = motor_s.tot_ang - (rev_bits << QEI_RES_BITS); // Calculate remaining angular position [-512..+511]

		// Handle wrap-around ...
		diff_revs = (signed char)(rev_bits - motor_s.est_revs); // Difference of Least Significant 8 bits
		motor_s.est_revs += (int)diff_revs; // Update revolution counter with difference

		diff_ang = motor_s.tot_ang - motor_s.prev_ang; // Form angle change since last request

		// Check if velocity update required
		if (diff_ang != 0)
		{ // Angular position change detected
			motor_s.est_period = PWM_MAX_VALUE; // Reset value for estimated QEI period
			qei_period = motor_s.qei_params.phase_period; // Assign measured QEI period

			motor_s.prev_period = qei_period; // Store QEI period for next iteration
			motor_s.prev_ang = motor_s.tot_ang; // Store total angular position for next iteration
			motor_s.prev_diff = diff_ang; // Store angular change
		} // if (diff_ang != 0)
		else
		{ // No Angular position change QEI. so use estimate
			motor_s.est_period += PWM_MAX_VALUE; // Extend estimated QEI period
			diff_ang = motor_s.prev_diff; // use previous non-zero difference angle

			if (motor_s.est_period > motor_s.prev_period)
			{ // Use estimated QEI period
				qei_period = motor_s.est_period; // Assign estimated QEI period
			} // if (motor_s.est_period > motor_s.prev_period)
			else
			{ // Use previous QEI period
				qei_period = motor_s.prev_period; // Assign previous QEI period
			} // if (motor_s.est_period > motor_s.prev_period)
		} // else !(diff_ang != 0)

		qei_period = filter_period( motor_s ,qei_period ); // Filter QEI period

		motor_s.prev_veloc = motor_s.est_veloc; // Store previous velocity
		motor_s.est_veloc = get_velocity( motor_s ,diff_ang ,qei_period ); // Update velocity estimate

#if (1 == VELOC_FILT)
		/* This filter prevents step-changes in estimated velocity due to bad QEI data.
		 * Probably no longer required
     */

		// Check for large negative change
		if (motor_s.est_veloc < (motor_s.prev_veloc - MAX_VELOC_INC))
		{ // Large negative change
			motor_s.est_veloc = (motor_s.prev_veloc - MAX_VELOC_INC); // Limit negative change
		} // if (motor_s.est_veloc < (motor_s.prev_veloc - MAX_VELOC_INC))
		else
		{
			// Check for large positive change
			if (motor_s.est_veloc > (motor_s.prev_veloc + MAX_VELOC_INC))
			{ // Large positive change
				motor_s.est_veloc = (motor_s.prev_veloc + MAX_VELOC_INC); // Limit positive change
			} // if (motor_s.est_veloc < (motor_s.prev_veloc + MAX_VELOC_INC))
		} // else !(motor_s.est_veloc < (motor_s.prev_veloc -MAX_VELOC_INC ))
#endif // VELOC_FILT

	} // if (motor_s.qei_params.phase_period > 0)
} // get_qei_data
/*****************************************************************************/
#pragma unsafe arrays
static void collect_sensor_data( // Collect sensor data and update motor state if necessary
	MOTOR_DATA_TYP &motor_s, // reference to structure containing motor data
	chanend c_pwm, // channel connecting to PWM client
	streaming chanend c_hall,  // channel connecting to Hall client
	streaming chanend c_qei,  // channel connecting to QEI client
	streaming chanend c_adc_cntrl // channel connecting to ADC client
)
{
	foc_hall_get_parameters( motor_s.hall_params ,c_hall ); // Get new hall state

	// Check for Hall error
	if (motor_s.hall_params.err)
	{ // Hall Error occured
		motor_s.err_data.err_flgs |= (1 << OVERCURRENT_ERR); // Add Hall error flag to error bit-map
		motor_s.err_data.line[OVERCURRENT_ERR] = __LINE__; // Store line where error occured
		motor_s.err_data.err_cnt[OVERCURRENT_ERR]++; // Increment error count

		// Check for too many Hall errors
		if (motor_s.err_data.err_cnt[OVERCURRENT_ERR] > motor_s.err_data.err_lim[OVERCURRENT_ERR])
		{ // Too many Hall errors
			motor_s.cnts[POWER_OFF] = 0; // Initialise power-down state counter
			motor_s.state = POWER_OFF; // Switch to power-down state
		} // if (motor_s.err_data.err_cnt[OVERCURRENT_ERR] > motor_s.err_data.err_lim[OVERCURRENT_ERR])

		return;
	} // if (motor_s.hall_params.err)

	// Check if Hall origin found
	if (0 == motor_s.hall_found)
	{
		find_hall_origin( motor_s ); // Test Hall-state for origin
	} // if (0 == motor_s.hall_found)

	// Regular-Sampling Mode

	get_qei_data( motor_s ,c_qei ); // Get raw QEI data, and compute QEI parameters (E.g. Velocity estimate)

	motor_s.meas_speed = abs( motor_s.est_veloc ); // NB Used to spot stalling behaviour

	// Check for safe speed
	if (SAFE_MAX_SPEED < motor_s.meas_speed)
	{ // Too fast!
		motor_s.err_data.err_flgs |= (1 << SPEED_ERR); // Add Speed error flag to error bit-map
		motor_s.err_data.line[SPEED_ERR] = __LINE__; // Store line where error occured

		acquire_lock(); printint(motor_s.id); printstr("WARNING: Safe Speed Exceeded="); printintln(motor_s.est_veloc); release_lock(); //MB~
		motor_s.cnts[WAIT_STOP] = 0; // Initialise stop-state counter
		motor_s.state = WAIT_STOP; // Switch to pause state
		return;
	} // if (4100 < motor_s.est_veloc)

	update_motor_state( motor_s ); // Update state of motor based on motor sensor data

	dq_to_pwm( motor_s ); // Convert DQ values to PWM values

	foc_pwm_put_parameters( motor_s.pwm_comms ,c_pwm ); // Update the PWM values

	// Get ADC sensor data here, in gap between PWM trigger and ADC capture
	foc_adc_get_parameters( motor_s.adc_params ,c_adc_cntrl );

	estimate_Iq_using_transforms( motor_s ); // Estimate Id and Iq from ADC sensor data

} // collect_sensor_data
/*****************************************************************************/
#pragma unsafe arrays
static void process_speed_command( // Decodes speed command, and implements changes
	MOTOR_DATA_TYP &motor_s, // reference to structure containing motor data
	chanend c_speed, // Channel between Motor_Control and IO_Display module
	CMD_IO_ENUM cmd_id // Command identifier from control interface
)
{
	int new_veloc;	// New Requested angular velocity
	int abs_diff;	// Absolute difference between old & new velocities
	int stop_motor = 0;	// Preset flag to motor does NOT need stopping


	// Determine command category
	switch(cmd_id)
	{
		case IO_CMD_INC_SPEED : // Increment Speed
			new_veloc = motor_s.req_veloc + motor_s.speed_inc;
		break; // case IO_CMD_INC_SPEED

		case IO_CMD_DEC_SPEED : // Decrement Speed
			new_veloc = motor_s.req_veloc - motor_s.speed_inc;
		break; // case IO_CMD_DEC_SPEED

		case IO_CMD_SET_SPEED : // Set absolute velocity
			c_speed :> new_veloc; // get command velocity
		break; // case IO_CMD_INC_SPEED

		case IO_CMD_FLIP_SPIN: // Flip Spin direction
			new_veloc = -motor_s.req_veloc; // Flip sign of velocity
		break; // case IO_CMD_FLIP_SPIN

    default: // Unsupported Speed command
			assert(0 == 1); // cmd_id NOT supported
    break; // default
	} // switch(cmd_id)

	abs_diff = abs(motor_s.req_veloc - new_veloc); // Form speed change

	// Check for valid speed change
	if (abs_diff)
	{ // Valid speed change
		if (0 != new_veloc)
		{ // Non-zero Speed
			// If necessary, clip command-speed into specified range
			if (new_veloc < -SPEC_MAX_SPEED)
			{ // Too Negative
				new_veloc = -SPEC_MAX_SPEED; // Clip to most negative specified speed
			} // if (new_veloc < -SPEC_MAX_SPEED)
			else
			{
				if (new_veloc > SPEC_MAX_SPEED)
				{ // Too Positive
					new_veloc = SPEC_MAX_SPEED; // Clip to most positive specified speed
				} // if (new_veloc > SPEC_MAX_SPEED)
				else
				{
					if ((-MIN_SPEED < new_veloc) && (new_veloc < 0))
					{ // NOT Negative enough
						new_veloc = -MIN_SPEED; // Clip to least negative specified speed
					} // if ((-MIN_SPEED < new_veloc) && (new_veloc < 0))
					else
					{
						if ((0 < new_veloc) && (new_veloc < MIN_SPEED))
						{ // NOT Positive enough
							new_veloc = MIN_SPEED; // Clip to least positive specified speed
						} // if ((0 < new_veloc) && (new_veloc < MIN_SPEED))
					} // else !((-MIN_SPEED < new_veloc) && (new_veloc < 0))
				} // else !(new_veloc > SPEC_MAX_SPEED)
			} // else !(new_veloc < -SPEC_MAX_SPEED)

			// Check for change of direction
			if ((new_veloc * motor_s.req_veloc) < 0)
			{	// Handle change of direction by a 'stop' and a 're-start'
				stop_motor = 1; // Set stop_motor flag.

				// NB Motor will automatically restart if Requested_Velocity >= MIN_SPEED
			} //if ((new_veloc * motor_s.req_veloc) < 0)
		} // if (0 != new_veloc)
		else
		{ // Zero Speed request
			stop_motor = 1; // Set stop_motor flag.

			// NB Motor will automatically restart when next received Requested_Velocity >= MIN_SPEED
		} // else (0 != new_veloc)

		// Check if 'stop-motor' requested
		if (stop_motor)
		{
			stop_pwm( motor_s ); // Stops motor by switching off PWM
			motor_s.cnts[WAIT_STOP] = 0; // Initialise stop-state counter
			motor_s.state = WAIT_STOP; // Switch to pause state
		} // if (stop_motor)

		motor_s.req_veloc = new_veloc; // Update requested velocity
	} // if (abs_diff)

} // process_speed_command
/*****************************************************************************/
#pragma unsafe arrays
static void use_motor ( // Start motor, and run step through different motor states
	MOTOR_DATA_TYP &motor_s, // reference to structure containing motor data
	chanend c_pwm, // channel connecting to PWM client
	streaming chanend c_hall, // channel connecting to Hall client
	streaming chanend c_qei, // channel connecting to QEI client
	streaming chanend c_adc_cntrl, // channel connecting to ADC client
	chanend c_speed, // Channel between Motor_Control and IO_Display module
	chanend c_commands, // channel connecting to CAN or Ethernet client (currently un-used)
	chanend c_wd  // Channel for communication with WatchDog server
)
{
	CMD_IO_ENUM cmd_id; // Command identifier from control interface


	motor_s.tymer :> motor_s.prev_time; // Store initialisation time-stamp

	// Main loop: terminates when POWER_OFF detected
	while (POWER_OFF != motor_s.state)
	{
#pragma xta endpoint "foc_loop"
		// Wait for ANY channel command
		select
		{
			case c_speed :> cmd_id:		// This case responds to speed control through shared I/O
#pragma xta label "foc_loop_speed_comms"

			// Determine shared I/O command
			switch(cmd_id)
			{
				case IO_CMD_GET_IQ : // Velocity data request
					c_speed <: motor_s.est_veloc; // Send estimated velocity
					c_speed <: motor_s.targ_vel; // Send target velocity
				break; // case IO_CMD_GET_IQ

				case IO_CMD_GET_FAULT : // Error status request
					c_speed <: motor_s.err_data.err_flgs; // Send Error status bit-map
				break; // case IO_CMD_GET_FAULT

		    default: // Must be a speed command!-)
					process_speed_command( motor_s ,c_speed ,cmd_id ); // Decodes speed command, and implements changes
		    break; // default
			} // switch(cmd_id)

			break; // case c_speed :> cmd_id:

			case c_commands :> cmd_id:		//This case responds to CAN or ETHERNET commands
#pragma xta label "foc_loop_shared_comms"

			// Determine CAN/Ehternet command
			switch(cmd_id)
			{
				case IO_CMD_GET_VALS : // Data request of type_1
					c_commands <: motor_s.est_veloc; // Send estimated velocity
					c_commands <: motor_s.adc_params.vals[ADC_PHASE_A]; // Send ADC Phase_A
					c_commands <: motor_s.adc_params.vals[ADC_PHASE_B]; // Send ADC Phase_B
				break; // case IO_CMD_GET_VALS

				case IO_CMD_GET_VALS2 : // Data request of type_2
					c_commands <: motor_s.adc_params.vals[ADC_PHASE_C]; // Send ADC Phase_C
					c_commands <: motor_s.pid_veloc; // Send output of Velocity-PID
					c_commands <: motor_s.pid_Id; // Send output of Id-PID
					c_commands <: motor_s.pid_Iq; // Send output of Iq-PID
				break; // case IO_CMD_GET_VALS2

				case IO_CMD_GET_FAULT :
					c_commands <: motor_s.err_data.err_flgs; // Send Error status bit-map
				break; // case IO_CMD_GET_FAULT

		    default: // Must be a speed command!-)
					process_speed_command( motor_s ,c_speed ,cmd_id ); // Decodes speed command, and implements changes
		    break; // default
			} // switch(cmd_id)
			break; // case c_commands :> cmd_id:

			default:	// No channel command ready, so update the motor state
				motor_s.iters++; // Increment No. of iterations

				// NB There is not enough band-width to probe all xscope data
				if ((1 == motor_s.id) || (motor_s.iters & 7)) // 31 probe at intervals
				{
					motor_s.xscope = 0; // Switch OFF xscope probe
				} // if ((motor_s.id) & !(motor_s.iters & 7))
				else
				{
					motor_s.xscope = 1; // Switch ON xscope probe
				} // if ((motor_s.id) & !(motor_s.iters & 7))

				// Collect sensor data and update motor state if necessary
				collect_sensor_data( motor_s ,c_pwm ,c_hall ,c_qei ,c_adc_cntrl );
			break; // default:
		}	// select

		c_wd <: WD_CMD_TICK; // Keep WatchDog alive

	}	// while (POWER_OFF != motor_s.state)

	// If we get to here, motor_s.state == POWER_OFF

	// Set PWM values to stop motor
	error_pwm_values( motor_s.pwm_comms.params.widths );

	foc_pwm_put_parameters( motor_s.pwm_comms ,c_pwm ); // Update the PWM with 'stop values'
} // use_motor
/*****************************************************************************/
void signal_servers_to_stop( // Signal then wait for other servers to terminate
	MOTOR_DATA_TYP &motor_s, // Structure containing motor data
	chanend c_wd, // Channel for communication with WatchDog server
	chanend c_pwm, // Channel for communication with PWM server
	streaming chanend c_hall, // Channel for communication with Hall server
	streaming chanend c_qei,  // Channel for communication with QEI server
	streaming chanend c_adc_cntrl // Channel for communication with ADC server
)
#define NUM_STOP_SERVERS 4 // WARNING: edit this line to indicate No of servers to close
{
	unsigned cmd; // Command from Server
	unsigned ts1;	// timestamp
	int run_cnt = NUM_STOP_SERVERS; // Initialise number of running servers


	// Signal other processes to stop ...

	c_pwm <: PWM_CMD_LOOP_STOP; // Stop PWM server
	c_adc_cntrl <: ADC_CMD_LOOP_STOP; // Stop ADC server
	c_qei <: QEI_CMD_LOOP_STOP; // Stop QEI server
	c_hall <: HALL_CMD_LOOP_STOP; // Stop Hall server

	// Loop until no more servers still running
	while(0 < run_cnt)
	{
		// Wait for ANY channel command
		select {
			case c_qei :> cmd : // QEI server
			{
				// If Shutdown acknowledged, decrement No. of running servers
				if (QEI_CMD_ACK == cmd) run_cnt--;
			} // case	c_qei
			break;

			case c_hall :> cmd : // Hall server
			{
				// If Shutdown acknowledged, decrement No. of running servers
				if (HALL_CMD_ACK == cmd) run_cnt--;
			} // case	c_hall
			break;

			case c_adc_cntrl :> cmd : // ADC server
			{
				// If Shutdown acknowledged, decrement No. of running servers
				if (ADC_CMD_ACK == cmd) run_cnt--;
			} // case	c_adc_cntrl
			break;

			case c_pwm :> cmd : // PWM server
			{
				// If Shutdown acknowledged, decrement No. of running servers
				if (PWM_CMD_ACK == cmd) run_cnt--;
			} // case	c_pwm
			break;

			default : // Wait a bit before re-try
				acquire_lock(); printint(motor_s.id);	release_lock();
				motor_s.tymer :> ts1;
				motor_s.tymer when timerafter(ts1 + MILLI_SEC) :> void;
			break; // default
		} // select
	} // while(0 < run_cnt)

	acquire_lock(); printstrln("");	release_lock();
} // signal_servers_to_stop
/*****************************************************************************/
static void error_handling( // Prints out error messages
	ERR_DATA_TYP &err_data_s // Reference to structure containing data for error-handling
)
{
	int err_cnt; // counter for different error types
	unsigned cur_flgs = err_data_s.err_flgs; // local copy of error flags


	// Loop through error types
	for (err_cnt=0; err_cnt<NUM_ERR_TYPS; err_cnt++)
	{
		// Test LS-bit for active flag
		if (cur_flgs & 1)
		{
			printstr( "Line " );
			printint( err_data_s.line[err_cnt] );
			printstr( ": " );
			printstrln( err_data_s.err_strs[err_cnt].str );
		} // if (cur_flgs & 1)

		cur_flgs >>= 1; // Discard flag
	} // for err_cnt

} // error_handling
/*****************************************************************************/
#pragma unsafe arrays
void run_motor (
	unsigned motor_id, // Unique motor identifier
	chanend c_wd,  // Channel for communication with WatchDog server
	chanend c_pwm, // channel connecting to PWM client
	streaming chanend c_hall,  // channel connecting to Hall client
	streaming chanend c_qei,  // channel connecting to QEI client
	streaming chanend c_adc_cntrl,  // channel connecting to ADC client
	chanend c_speed,  // Channel between Motor_Control and IO_Display module
	chanend c_commands  // channel connecting to CAN or Ethernet client (currently un-used)
)
{
	MOTOR_DATA_TYP motor_s; // Structure containing motor data
	unsigned ts1;	// timestamp


	acquire_lock();
	printstr("                      Motor_");
	printint(motor_id);
	printstrln(" Starts");
	release_lock();

	// Allow the rest of the system to settle
	motor_s.tymer :> ts1; // Get current time
	motor_s.tymer when timerafter(ts1 + (MILLI_400_SECS << 1)) :> ts1; // Wait a bit

	init_motor( motor_s ,motor_id );	// Initialise motor data

	init_pwm( motor_s.pwm_comms ,c_pwm ,motor_id );	// Initialise PWM communication data

	// Wait for other processes to start ...
	wait_for_servers_to_start( motor_s ,c_wd ,c_pwm ,c_hall ,c_qei ,c_adc_cntrl );

	acquire_lock();
	printstr("                      Motor_");
	printint(motor_id);
	printstrln(" Starts");
	release_lock();

	// start-and-run motor
	use_motor( motor_s ,c_pwm ,c_hall ,c_qei ,c_adc_cntrl ,c_speed ,c_commands ,c_wd );

	// Closedown other processes ...
	signal_servers_to_stop( motor_s ,c_wd ,c_pwm ,c_hall ,c_qei ,c_adc_cntrl );

	if (motor_id)
	{
		acquire_lock();
		if (motor_s.err_data.err_flgs)
		{
			printstr( "Demo Ended Due to Following Errors on Motor " );
			printintln(motor_s.id);
			error_handling( motor_s.err_data );
		} // if (motor_s.err_data.err_flgs)
		else
		{
			printstrln( "Demo Ended Normally" );
		} // else !(motor_s.err_data.err_flgs)
		release_lock();

		_Exit(1); // Exit without flushing buffers
	} // if (motor_id)

} // run_motor
/*****************************************************************************/
// inner_loop.xc
