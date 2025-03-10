// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module sui::sui_system {
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::staking_pool::{delegation_activation_epoch, StakedSui};
    use sui::locked_coin::{Self, LockedCoin};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::validator::{Self, Validator};
    use sui::validator_set::{Self, ValidatorSet};
    use sui::stake_subsidy::{Self, StakeSubsidy};
    use sui::vec_map::{Self, VecMap};
    use sui::vec_set::{Self, VecSet};
    use std::option;
    use std::vector;
    use sui::epoch_time_lock::EpochTimeLock;
    use sui::epoch_time_lock;
    use sui::pay;
    use sui::event;
    use sui::table::Table;
    use sui::dynamic_field;
    use sui::url;
    use std::string;
    use std::ascii;

    friend sui::genesis;

    #[test_only]
    friend sui::governance_test_utils;

    /// A list of system config parameters.
    // TDOO: We will likely add more, a few potential ones:
    // - the change in stake across epochs can be at most +/- x%
    // - the change in the validator set across epochs can be at most x validators
    //
    struct SystemParameters has store {
        /// Lower-bound on the amount of stake required to become a validator.
        // TODO: use a different threshold for new validator joining vs. validator keeping their
        // spot in the validator set.
        min_validator_stake: u64,
        /// Maximum number of active validators at any moment.
        /// We do not allow the number of validators in any epoch to go above this.
        max_validator_count: u64,

        /// The starting epoch in which various on-chain governance features take effect:
        /// - stake subsidies are paid out
        /// - TODO validators with stake less than a 'validator_stake_threshold' are
        ///   kicked from the validator set
        governance_start_epoch: u64,
    }

    /// The top-level object containing all information of the Sui system.
    struct SuiSystemStateInner has store {
        /// The current epoch ID, starting from 0.
        epoch: u64,
        /// The current protocol version, starting from 1.
        protocol_version: u64,
        /// Contains all information about the validators.
        validators: ValidatorSet,
        /// The storage fund.
        storage_fund: Balance<SUI>,
        /// A list of system config parameters.
        parameters: SystemParameters,
        /// The reference gas price for the current epoch.
        reference_gas_price: u64,
        /// A map storing the records of validator reporting each other.
        /// There is an entry in the map for each validator that has been reported
        /// at least once. The entry VecSet contains all the validators that reported
        /// them. If a validator has never been reported they don't have an entry in this map.
        /// This map persists across epoch: a peer continues being in a reported state until the
        /// reporter doesn't explicitly remove their report.
        /// Note that in case we want to support validator address change in future,
        /// the reports should be based on validator ids
        validator_report_records: VecMap<address, VecSet<address>>,
        /// Schedule of stake subsidies given out each epoch.
        stake_subsidy: StakeSubsidy,

        /// Whether the system is running in a downgraded safe mode due to a non-recoverable bug.
        /// This is set whenever we failed to execute advance_epoch, and ended up executing advance_epoch_safe_mode.
        /// It can be reset once we are able to successfully execute advance_epoch.
        /// TODO: Down the road we may want to save a few states such as pending gas rewards, so that we could
        /// redistribute them.
        safe_mode: bool,
        /// Unix timestamp of the current epoch start
        epoch_start_timestamp_ms: u64,
    }

    struct SuiSystemState has key {
        id: UID,
        version: u64,
    }

    /// Event containing system-level epoch information, emitted during
    /// the epoch advancement transaction.
    struct SystemEpochInfo has copy, drop {
        epoch: u64,
        protocol_version: u64,
        reference_gas_price: u64,
        total_stake: u64,
        storage_fund_inflows: u64,
        storage_fund_outflows: u64,
        storage_fund_balance: u64,
        stake_subsidy_amount: u64,
        total_gas_fees: u64,
        total_stake_rewards: u64,
    }

    // Errors
    const ENotValidator: u64 = 0;
    const ELimitExceeded: u64 = 1;
    const EEpochNumberMismatch: u64 = 2;
    const ECannotReportOneself: u64 = 3;
    const EReportRecordNotFound: u64 = 4;
    const EBpsTooLarge: u64 = 5;
    const EStakedSuiFromWrongEpoch: u64 = 6;

    const BASIS_POINT_DENOMINATOR: u128 = 10000;

    // ==== functions that can only be called by genesis ====

    /// Create a new SuiSystemState object and make it shared.
    /// This function will be called only once in genesis.
    public(friend) fun create(
        validators: vector<Validator>,
        stake_subsidy_fund: Balance<SUI>,
        storage_fund: Balance<SUI>,
        max_validator_count: u64,
        min_validator_stake: u64,
        governance_start_epoch: u64,
        initial_stake_subsidy_amount: u64,
        protocol_version: u64,
        system_state_version: u64,
        epoch_start_timestamp_ms: u64,
        ctx: &mut TxContext,
    ) {
        let validators = validator_set::new(validators, ctx);
        let reference_gas_price = validator_set::derive_reference_gas_price(&validators);
        let system_state = SuiSystemStateInner {
            epoch: 0,
            protocol_version,
            validators,
            storage_fund,
            parameters: SystemParameters {
                min_validator_stake,
                max_validator_count,
                governance_start_epoch,
            },
            reference_gas_price,
            validator_report_records: vec_map::empty(),
            stake_subsidy: stake_subsidy::create(stake_subsidy_fund, initial_stake_subsidy_amount),
            safe_mode: false,
            epoch_start_timestamp_ms,
        };
        let self = SuiSystemState {
            // Use a hardcoded ID.
            id: object::sui_system_state(),
            version: system_state_version,
        };
        dynamic_field::add(&mut self.id, system_state_version, system_state);
        transfer::share_object(self);
    }

    // ==== entry functions ====

    /// Can be called by anyone who wishes to become a validator candidate and starts accuring delegated
    /// stakes in their staking pool. Once they have at least `min_validator_stake` amount of stake they
    /// can call `request_add_validator` to officially become an active validator at the next epoch.
    /// Aborts if the caller is already a pending or active validator, or a validator candidate.
    public entry fun request_add_validator_candidate(
        wrapper: &mut SuiSystemState,
        pubkey_bytes: vector<u8>,
        network_pubkey_bytes: vector<u8>,
        worker_pubkey_bytes: vector<u8>,
        proof_of_possession: vector<u8>,
        name: vector<u8>,
        description: vector<u8>,
        image_url: vector<u8>,
        project_url: vector<u8>,
        net_address: vector<u8>,
        p2p_address: vector<u8>,
        primary_address: vector<u8>,
        worker_address: vector<u8>,
        gas_price: u64,
        commission_rate: u64,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        let validator = validator::new(
            tx_context::sender(ctx),
            pubkey_bytes,
            network_pubkey_bytes,
            worker_pubkey_bytes,
            proof_of_possession,
            name,
            description,
            image_url,
            project_url,
            net_address,
            p2p_address,
            primary_address,
            worker_address,
            option::none(),
            option::none(),
            gas_price,
            commission_rate,
            false, // not an initial validator active at genesis
            ctx
        );

        validator_set::request_add_validator_candidate(&mut self.validators, validator);
    }

    /// Called by a validator candidate to remove themselves from the candidacy. After this call
    /// their staking pool becomes deactive.
    public entry fun request_remove_validator_candidate(
        wrapper: &mut SuiSystemState,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        validator_set::request_remove_validator_candidate(&mut self.validators, ctx);
    }

    /// Called by a validator candidate to add themselves to the active validator set beginning next epoch.
    /// Aborts if the validator is a duplicate with one of the pending or active validators, or if the amount of
    /// stake the validator has doesn't meet the min threshold, or if the number of new validators for the next
    /// epoch has already reached the maximum.
    public entry fun request_add_validator(
        wrapper: &mut SuiSystemState,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        assert!(
            validator_set::next_epoch_validator_count(&self.validators) < self.parameters.max_validator_count,
            ELimitExceeded,
        );

        validator_set::request_add_validator(&mut self.validators, self.parameters.min_validator_stake, ctx);
    }

    /// A validator can call this function to request a removal in the next epoch.
    /// We use the sender of `ctx` to look up the validator
    /// (i.e. sender must match the sui_address in the validator).
    /// At the end of the epoch, the `validator` object will be returned to the sui_address
    /// of the validator.
    public entry fun request_remove_validator(
        wrapper: &mut SuiSystemState,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        validator_set::request_remove_validator(
            &mut self.validators,
            ctx,
        )
    }

    /// A validator can call this entry function to submit a new gas price quote, to be
    /// used for the reference gas price calculation at the end of the epoch.
    public entry fun request_set_gas_price(
        wrapper: &mut SuiSystemState,
        new_gas_price: u64,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        validator_set::request_set_gas_price(
            &mut self.validators,
            new_gas_price,
            ctx
        )
    }

    /// A validator can call this entry function to set a new commission rate, updated at the end of the epoch.
    public entry fun request_set_commission_rate(
        wrapper: &mut SuiSystemState,
        new_commission_rate: u64,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        validator_set::request_set_commission_rate(
            &mut self.validators,
            new_commission_rate,
            ctx
        )
    }

    /// Add delegated stake to a validator's staking pool.
    public entry fun request_add_delegation(
        wrapper: &mut SuiSystemState,
        delegate_stake: Coin<SUI>,
        validator_address: address,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        validator_set::request_add_delegation(
            &mut self.validators,
            validator_address,
            coin::into_balance(delegate_stake),
            option::none(),
            ctx,
        );
    }

    /// Add delegated stake to a validator's staking pool using multiple coins.
    public entry fun request_add_delegation_mul_coin(
        wrapper: &mut SuiSystemState,
        delegate_stakes: vector<Coin<SUI>>,
        stake_amount: option::Option<u64>,
        validator_address: address,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        let balance = extract_coin_balance(delegate_stakes, stake_amount, ctx);
        validator_set::request_add_delegation(&mut self.validators, validator_address, balance, option::none(), ctx);
    }

    /// Add delegated stake to a validator's staking pool using a locked SUI coin.
    public entry fun request_add_delegation_with_locked_coin(
        wrapper: &mut SuiSystemState,
        delegate_stake: LockedCoin<SUI>,
        validator_address: address,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        let (balance, lock) = locked_coin::into_balance(delegate_stake);
        validator_set::request_add_delegation(&mut self.validators, validator_address, balance, option::some(lock), ctx);
    }

    /// Add delegated stake to a validator's staking pool using multiple locked SUI coins.
    public entry fun request_add_delegation_mul_locked_coin(
        wrapper: &mut SuiSystemState,
        delegate_stakes: vector<LockedCoin<SUI>>,
        stake_amount: option::Option<u64>,
        validator_address: address,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        let (balance, lock) = extract_locked_coin_balance(delegate_stakes, stake_amount, ctx);
        validator_set::request_add_delegation(
            &mut self.validators,
            validator_address,
            balance,
            option::some(lock),
            ctx
        );
    }

    /// Withdraw some portion of a delegation from a validator's staking pool.
    public entry fun request_withdraw_delegation(
        wrapper: &mut SuiSystemState,
        staked_sui: StakedSui,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        assert!(delegation_activation_epoch(&staked_sui) <= tx_context::epoch(ctx), 0);
        validator_set::request_withdraw_delegation(
            &mut self.validators, staked_sui, ctx,
        );
    }

    /// Report a validator as a bad or non-performant actor in the system.
    /// Succeeds iff both the sender and the input `validator_addr` are active validators
    /// and they are not the same address. This function is idempotent.
    public entry fun report_validator(
        wrapper: &mut SuiSystemState,
        validator_addr: address,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        let sender = tx_context::sender(ctx);
        // Both the reporter and the reported have to be validators.
        assert!(validator_set::is_active_validator_by_sui_address(&self.validators, sender), ENotValidator);
        assert!(validator_set::is_active_validator_by_sui_address(&self.validators, validator_addr), ENotValidator);
        assert!(sender != validator_addr, ECannotReportOneself);

        if (!vec_map::contains(&self.validator_report_records, &validator_addr)) {
            vec_map::insert(&mut self.validator_report_records, validator_addr, vec_set::singleton(sender));
        } else {
            let reporters = vec_map::get_mut(&mut self.validator_report_records, &validator_addr);
            if (!vec_set::contains(reporters, &sender)) {
                vec_set::insert(reporters, sender);
            }
        }
    }

    /// Undo a `report_validator` action. Aborts if the sender has not previously reported the
    /// `validator_addr`.
    public entry fun undo_report_validator(
        wrapper: &mut SuiSystemState,
        validator_addr: address,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        let sender = tx_context::sender(ctx);

        assert!(vec_map::contains(&self.validator_report_records, &validator_addr), EReportRecordNotFound);
        let reporters = vec_map::get_mut(&mut self.validator_report_records, &validator_addr);
        assert!(vec_set::contains(reporters, &sender), EReportRecordNotFound);
        vec_set::remove(reporters, &sender);
        if (vec_set::is_empty(reporters)) {
            vec_map::remove(&mut self.validator_report_records, &validator_addr);
        }
    }

    // ==== validator metadata management functions ====

    /// Update a validator's name.
    public entry fun update_validator_name(
        self: &mut SuiSystemState,
        name: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_name(validator, string::from_ascii(ascii::string(name)));
    }

    /// Update a validator's description
    public entry fun update_validator_description(
        self: &mut SuiSystemState,
        description: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_description(validator, string::from_ascii(ascii::string(description)));
    }

    /// Update a validator's image url
    public entry fun update_validator_image_url(
        self: &mut SuiSystemState,
        image_url: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_image_url(validator, url::new_unsafe_from_bytes(image_url));
    }

    /// Update a validator's project url
    public entry fun update_validator_project_url(
        self: &mut SuiSystemState,
        project_url: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_project_url(validator, url::new_unsafe_from_bytes(project_url));
    }

    /// Update a validator's network address.
    /// The change will only take effects starting from the next epoch.
    public entry fun update_validator_next_epoch_network_address(
        self: &mut SuiSystemState,
        network_address: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_next_epoch_network_address(validator, network_address);
    }

    /// Update a validator's p2p address.
    /// The change will only take effects starting from the next epoch.
    public entry fun update_validator_next_epoch_p2p_address(
        self: &mut SuiSystemState,
        p2p_address: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_next_epoch_p2p_address(validator, p2p_address);
    }

    /// Update a validator's narwhal primary address.
    /// The change will only take effects starting from the next epoch.
    public entry fun update_validator_next_epoch_primary_address(
        self: &mut SuiSystemState,
        primary_address: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_next_epoch_primary_address(validator, primary_address);
    }

    /// Update a validator's narwhal worker address.
    /// The change will only take effects starting from the next epoch.
    public entry fun update_validator_next_epoch_worker_address(
        self: &mut SuiSystemState,
        worker_address: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_next_epoch_worker_address(validator, worker_address);
    }

    /// Update a validator's public key of protocol key and proof of possession.
    /// The change will only take effects starting from the next epoch.
    public entry fun update_validator_next_epoch_protocol_pubkey(
        self: &mut SuiSystemState,
        protocol_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_next_epoch_protocol_pubkey(validator, protocol_pubkey, proof_of_possession);
    }

    /// Update a validator's public key of worker key.
    /// The change will only take effects starting from the next epoch.
    public entry fun update_validator_next_epoch_worker_pubkey(
        self: &mut SuiSystemState,
        worker_pubkey: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_next_epoch_worker_pubkey(validator, worker_pubkey);
    }

    /// Update a validator's public key of network key.
    /// The change will only take effects starting from the next epoch.
    public entry fun update_validator_next_epoch_network_pubkey(
        self: &mut SuiSystemState,
        network_pubkey: vector<u8>,
        ctx: &TxContext,
    ) {
        let self = load_system_state_mut(self);
        let validator = validator_set::get_active_or_pending_validator_mut(&mut self.validators, ctx);
        validator::update_next_epoch_network_pubkey(validator, network_pubkey);
    }

    /// This function should be called at the end of an epoch, and advances the system to the next epoch.
    /// It does the following things:
    /// 1. Add storage charge to the storage fund.
    /// 2. Burn the storage rebates from the storage fund. These are already refunded to transaction sender's
    ///    gas coins.
    /// 3. Distribute computation charge to validator stake and delegation stake.
    /// 4. Update all validators.
    public entry fun advance_epoch(
        wrapper: &mut SuiSystemState,
        new_epoch: u64,
        next_protocol_version: u64,
        storage_charge: u64,
        computation_charge: u64,
        storage_rebate: u64,
        storage_fund_reinvest_rate: u64, // share of storage fund's rewards that's reinvested
                                         // into storage fund, in basis point.
        reward_slashing_rate: u64, // how much rewards are slashed to punish a validator, in bps.
        epoch_start_timestamp_ms: u64, // Timestamp of the epoch start
        new_system_state_version: u64,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        // Validator will make a special system call with sender set as 0x0.
        assert!(tx_context::sender(ctx) == @0x0, 0);
        let old_protocol_version = self.protocol_version;

        self.epoch_start_timestamp_ms = epoch_start_timestamp_ms;

        let bps_denominator_u64 = (BASIS_POINT_DENOMINATOR as u64);
        // Rates can't be higher than 100%.
        assert!(
            storage_fund_reinvest_rate <= bps_denominator_u64
            && reward_slashing_rate <= bps_denominator_u64,
            EBpsTooLarge,
        );

        let total_validators_stake = validator_set::total_stake(&self.validators);
        let storage_fund_balance = balance::value(&self.storage_fund);
        let total_stake = storage_fund_balance + total_validators_stake;

        let storage_reward = balance::create_staking_rewards(storage_charge);
        let computation_reward = balance::create_staking_rewards(computation_charge);

        // Include stake subsidy in the rewards given out to validators and delegators.
        // Delay distributing any stake subsidies until after `governance_start_epoch`.
        let stake_subsidy = if (tx_context::epoch(ctx) >= self.parameters.governance_start_epoch) {
            stake_subsidy::advance_epoch(&mut self.stake_subsidy)
        } else {
            balance::zero()
        };

        let stake_subsidy_amount = balance::value(&stake_subsidy);
        balance::join(&mut computation_reward, stake_subsidy);

        let total_stake_u128 = (total_stake as u128);
        let computation_charge_u128 = (computation_charge as u128);

        balance::join(&mut self.storage_fund, storage_reward);

        let storage_fund_reward_amount = (storage_fund_balance as u128) * computation_charge_u128 / total_stake_u128;
        let storage_fund_reward = balance::split(&mut computation_reward, (storage_fund_reward_amount as u64));
        let storage_fund_reinvestment_amount =
            storage_fund_reward_amount * (storage_fund_reinvest_rate as u128) / BASIS_POINT_DENOMINATOR;
        let storage_fund_reinvestment = balance::split(
            &mut storage_fund_reward,
            (storage_fund_reinvestment_amount as u64),
        );
        balance::join(&mut self.storage_fund, storage_fund_reinvestment);

        self.epoch = self.epoch + 1;
        // Sanity check to make sure we are advancing to the right epoch.
        assert!(new_epoch == self.epoch, 0);
        let total_rewards_amount =
            balance::value(&computation_reward)+ balance::value(&storage_fund_reward);

        validator_set::advance_epoch(
            &mut self.validators,
            &mut computation_reward,
            &mut storage_fund_reward,
            &mut self.validator_report_records,
            reward_slashing_rate,
            ctx,
        );

        self.protocol_version = next_protocol_version;

        // Derive the reference gas price for the new epoch
        self.reference_gas_price = validator_set::derive_reference_gas_price(&self.validators);
        // Because of precision issues with integer divisions, we expect that there will be some
        // remaining balance in `storage_fund_reward` and `computation_reward`.
        // All of these go to the storage fund.
        balance::join(&mut self.storage_fund, storage_fund_reward);
        balance::join(&mut self.storage_fund, computation_reward);

        // Destroy the storage rebate.
        assert!(balance::value(&self.storage_fund) >= storage_rebate, 0);
        balance::destroy_storage_rebates(balance::split(&mut self.storage_fund, storage_rebate));

        let new_total_stake = validator_set::total_stake(&self.validators);

        event::emit(
            SystemEpochInfo {
                epoch: self.epoch,
                protocol_version: self.protocol_version,
                reference_gas_price: self.reference_gas_price,
                total_stake: new_total_stake,
                storage_fund_inflows: storage_charge + (storage_fund_reinvestment_amount as u64),
                storage_fund_outflows: storage_rebate,
                storage_fund_balance: balance::value(&self.storage_fund),
                stake_subsidy_amount,
                total_gas_fees: computation_charge,
                total_stake_rewards: total_rewards_amount,
            }
        );
        self.safe_mode = false;

        if (new_system_state_version != wrapper.version) {
            // If we are upgrading the system state, we need to make sure that the protocol version
            // is also upgraded.
            assert!(old_protocol_version != next_protocol_version, 0);
            let cur_state: SuiSystemStateInner = dynamic_field::remove(&mut wrapper.id, wrapper.version);
            let new_state = upgrade_system_state(cur_state);
            wrapper.version = new_system_state_version;
            dynamic_field::add(&mut wrapper.id, wrapper.version, new_state);
        };
    }

    /// An extremely simple version of advance_epoch.
    /// This is called in two situations:
    ///   - When the call to advance_epoch failed due to a bug, and we want to be able to keep the
    ///     system running and continue making epoch changes.
    ///   - When advancing to a new protocol version, we want to be able to change the protocol
    ///     version
    public entry fun advance_epoch_safe_mode(
        wrapper: &mut SuiSystemState,
        new_epoch: u64,
        next_protocol_version: u64,
        ctx: &mut TxContext,
    ) {
        let self = load_system_state_mut(wrapper);
        // Validator will make a special system call with sender set as 0x0.
        assert!(tx_context::sender(ctx) == @0x0, 0);

        self.epoch = new_epoch;
        self.protocol_version = next_protocol_version;
        self.safe_mode = true;
    }

    public entry fun consensus_commit_prologue(
        clock: &mut Clock,
        timestamp_ms: u64,
        ctx: &TxContext,
    ) {
        // Validator will make a special system call with sender set as 0x0.
        assert!(tx_context::sender(ctx) == @0x0, 0);

        clock::set_timestamp(clock, timestamp_ms);
    }

    /// Return the current epoch number. Useful for applications that need a coarse-grained concept of time,
    /// since epochs are ever-increasing and epoch changes are intended to happen every 24 hours.
    public fun epoch(wrapper: &SuiSystemState): u64 {
        let self = load_system_state(wrapper);
        self.epoch
    }

    /// Returns unix timestamp of the start of current epoch
    public fun epoch_start_timestamp_ms(wrapper: &SuiSystemState): u64 {
        let self = load_system_state(wrapper);
        self.epoch_start_timestamp_ms
    }

    /// Returns the total amount staked with `validator_addr`.
    /// Aborts if `validator_addr` is not an active validator.
    public fun validator_stake_amount(wrapper: &SuiSystemState, validator_addr: address): u64 {
        let self = load_system_state(wrapper);
        validator_set::validator_total_stake_amount(&self.validators, validator_addr)
    }

    /// Returns the staking pool id of a given validator.
    /// Aborts if `validator_addr` is not an active validator.
    public fun validator_staking_pool_id(wrapper: &SuiSystemState, validator_addr: address): ID {
        let self = load_system_state(wrapper);
        validator_set::validator_staking_pool_id(&self.validators, validator_addr)
    }

    /// Returns reference to the staking pool mappings that map pool ids to active validator addresses
    public fun validator_staking_pool_mappings(wrapper: &SuiSystemState): &Table<ID, address> {
        let self = load_system_state(wrapper);
        validator_set::staking_pool_mappings(&self.validators)
    }

    /// Returns all the validators who are currently reporting `addr`
    public fun get_reporters_of(wrapper: &SuiSystemState, addr: address): VecSet<address> {
        let self = load_system_state(wrapper);
        if (vec_map::contains(&self.validator_report_records, &addr)) {
            *vec_map::get(&self.validator_report_records, &addr)
        } else {
            vec_set::empty()
        }
    }

    fun load_system_state(self: &SuiSystemState): &SuiSystemStateInner {
        dynamic_field::borrow(&self.id, self.version)
    }

    fun load_system_state_mut(self: &mut SuiSystemState): &mut SuiSystemStateInner {
        dynamic_field::borrow_mut(&mut self.id, self.version)
    }

    fun upgrade_system_state(cur_state: SuiSystemStateInner): SuiSystemStateInner {
        // Whenever we upgrade the system state version, we will have to first
        // ship a framework upgrade that introduces a new system state type, and make this
        // function generate such type from the old state.
        cur_state
    }

    /// Extract required Balance from vector of Coin<SUI>, transfer the remainder back to sender.
    fun extract_coin_balance(coins: vector<Coin<SUI>>, amount: option::Option<u64>, ctx: &mut TxContext): Balance<SUI> {
        let merged_coin = vector::pop_back(&mut coins);
        pay::join_vec(&mut merged_coin, coins);

        let total_balance = coin::into_balance(merged_coin);
        // return the full amount if amount is not specified
        if (option::is_some(&amount)) {
            let amount = option::destroy_some(amount);
            let balance = balance::split(&mut total_balance, amount);
            // transfer back the remainder if non zero.
            if (balance::value(&total_balance) > 0) {
                transfer::transfer(coin::from_balance(total_balance, ctx), tx_context::sender(ctx));
            } else {
                balance::destroy_zero(total_balance);
            };
            balance
        } else {
            total_balance
        }
    }

    /// Extract required Balance from vector of LockedCoin<SUI>, transfer the remainder back to sender.
    fun extract_locked_coin_balance(
        coins: vector<LockedCoin<SUI>>,
        amount: option::Option<u64>,
        ctx: &mut TxContext
    ): (Balance<SUI>, EpochTimeLock) {
        let (total_balance, first_lock) = locked_coin::into_balance(vector::pop_back(&mut coins));
        let (i, len) = (0, vector::length(&coins));
        while (i < len) {
            let (balance, lock) = locked_coin::into_balance(vector::pop_back(&mut coins));
            // Make sure all time locks are the same
            assert!(epoch_time_lock::epoch(&lock) == epoch_time_lock::epoch(&first_lock), 0);
            epoch_time_lock::destroy_unchecked(lock);
            balance::join(&mut total_balance, balance);
            i = i + 1
        };
        vector::destroy_empty(coins);

        // return the full amount if amount is not specified
        if (option::is_some(&amount)){
            let amount = option::destroy_some(amount);
            let balance = balance::split(&mut total_balance, amount);
            if (balance::value(&total_balance) > 0) {
                locked_coin::new_from_balance(total_balance, first_lock, tx_context::sender(ctx), ctx);
            } else {
                balance::destroy_zero(total_balance);
            };
            (balance, first_lock)
        } else{
            (total_balance, first_lock)
        }
    }

    /// Return the current validator set
    public fun validators(wrapper: &SuiSystemState): &ValidatorSet {
        let self = load_system_state(wrapper);
        &self.validators
    }

    /// Return the currently active validator by address
    public fun active_validator_by_address(self: &SuiSystemState, validator_address: address): &Validator {
        validator_set::get_active_validator_ref(validators(self), validator_address)
    }

    /// Return the currently pending validator by address
    public fun pending_validator_by_address(self: &SuiSystemState, validator_address: address): &Validator {
        validator_set::get_pending_validator_ref(validators(self), validator_address)
    }

    #[test_only]
    public fun set_epoch_for_testing(wrapper: &mut SuiSystemState, epoch_num: u64) {
        let self = load_system_state_mut(wrapper);
        self.epoch = epoch_num
    }
}
