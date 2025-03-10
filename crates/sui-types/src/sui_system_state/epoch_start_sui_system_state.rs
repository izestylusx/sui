// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::collections::{BTreeMap, HashMap};

use crate::base_types::{AuthorityName, EpochId, SuiAddress};
use crate::committee::{Committee, CommitteeWithNetworkMetadata, NetworkMetadata, StakeUnit};
use anemo::PeerId;
use multiaddr::Multiaddr;
use narwhal_config::{Committee as NarwhalCommittee, WorkerCache, WorkerIndex};
use serde::{Deserialize, Serialize};
use sui_protocol_config::ProtocolVersion;

/// This type captures the minimum amount of information from SuiSystemState needed by a validator
/// to run the protocol. This allows us to decouple from the actual SuiSystemState type, and hence
/// do not need to evolve it when we upgrade the SuiSystemState type.
/// Evolving EpochStartSystemState is also a lot easier in that we could add optional fields
/// and fill them with None for older versions. When we absolutely must delete fields, we could
/// also add new db tables to store the new version. This is OK because we only store one copy of
/// this as part of EpochStartConfiguration for the most recent epoch in the db.
#[derive(Serialize, Deserialize, Debug, Eq, PartialEq)]
pub struct EpochStartSystemState {
    pub epoch: EpochId,
    pub protocol_version: u64,
    pub reference_gas_price: u64,
    pub safe_mode: bool,
    pub epoch_start_timestamp_ms: u64,
    pub active_validators: Vec<EpochStartValidatorInfo>,
}

impl EpochStartSystemState {
    pub fn new_for_testing() -> Self {
        Self::new_for_testing_with_epoch(0)
    }

    pub fn new_for_testing_with_epoch(epoch: EpochId) -> Self {
        Self {
            epoch,
            protocol_version: ProtocolVersion::MIN.as_u64(),
            reference_gas_price: 1,
            safe_mode: false,
            epoch_start_timestamp_ms: 0,
            active_validators: vec![],
        }
    }

    pub fn get_sui_committee(&self) -> CommitteeWithNetworkMetadata {
        let mut voting_rights = BTreeMap::new();
        let mut network_metadata = BTreeMap::new();
        for validator in &self.active_validators {
            let (name, voting_stake, metadata) = validator.to_stake_and_network_metadata();
            voting_rights.insert(name, voting_stake);
            network_metadata.insert(name, metadata);
        }
        CommitteeWithNetworkMetadata {
            committee: Committee::new(self.epoch, voting_rights)
                // unwrap is safe because we should have verified the committee on-chain.
                // TODO: Make sure we actually verify it.
                .unwrap(),
            network_metadata,
        }
    }

    #[allow(clippy::mutable_key_type)]
    pub fn get_narwhal_committee(&self) -> NarwhalCommittee {
        let narwhal_committee = self
            .active_validators
            .iter()
            .map(|validator| {
                let authority = narwhal_config::Authority {
                    stake: validator.voting_power as narwhal_config::Stake,
                    primary_address: validator.narwhal_primary_address.clone(),
                    network_key: validator.narwhal_network_pubkey.clone(),
                };
                (validator.protocol_pubkey.clone(), authority)
            })
            .collect();

        narwhal_config::Committee {
            authorities: narwhal_committee,
            epoch: self.epoch as narwhal_config::Epoch,
        }
    }

    pub fn get_authority_names_to_peer_ids(&self) -> HashMap<AuthorityName, PeerId> {
        self.active_validators
            .iter()
            .map(|validator| {
                let name = validator.authority_name();
                let peer_id = PeerId(validator.narwhal_network_pubkey.0.to_bytes());

                (name, peer_id)
            })
            .collect()
    }

    #[allow(clippy::mutable_key_type)]
    pub fn get_narwhal_worker_cache(&self, transactions_address: &Multiaddr) -> WorkerCache {
        let workers: BTreeMap<narwhal_crypto::PublicKey, WorkerIndex> = self
            .active_validators
            .iter()
            .map(|validator| {
                let workers = [(
                    0,
                    narwhal_config::WorkerInfo {
                        name: validator.narwhal_worker_pubkey.clone(),
                        transactions: transactions_address.clone(),
                        worker_address: validator.narwhal_worker_address.clone(),
                    },
                )]
                .into_iter()
                .collect();
                let worker_index = WorkerIndex(workers);

                (validator.protocol_pubkey.clone(), worker_index)
            })
            .collect();
        WorkerCache {
            workers,
            epoch: self.epoch,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Eq, PartialEq)]
pub struct EpochStartValidatorInfo {
    pub sui_address: SuiAddress,
    pub protocol_pubkey: narwhal_crypto::PublicKey,
    pub narwhal_network_pubkey: narwhal_crypto::NetworkPublicKey,
    pub narwhal_worker_pubkey: narwhal_crypto::NetworkPublicKey,
    pub sui_net_address: Multiaddr,
    pub p2p_address: Multiaddr,
    pub narwhal_primary_address: Multiaddr,
    pub narwhal_worker_address: Multiaddr,
    pub voting_power: StakeUnit,
}

impl EpochStartValidatorInfo {
    pub fn to_stake_and_network_metadata(&self) -> (AuthorityName, StakeUnit, NetworkMetadata) {
        (
            (&self.protocol_pubkey).into(),
            self.voting_power,
            NetworkMetadata {
                network_pubkey: self.narwhal_network_pubkey.clone(),
                network_address: self.sui_net_address.clone(),
                p2p_address: self.p2p_address.clone(),
            },
        )
    }
    pub fn authority_name(&self) -> AuthorityName {
        (&self.protocol_pubkey).into()
    }
}
