// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use super::*;
use crate::utils::build_network;
use anemo::Result;
use fastcrypto::ed25519::Ed25519PublicKey;
use futures::stream::FuturesUnordered;
use std::collections::{BTreeMap, HashSet};
use sui_types::committee::{Committee, NetworkMetadata};
use sui_types::crypto::get_authority_key_pair;
use sui_types::crypto::AuthorityPublicKeyBytes;
use sui_types::crypto::KeypairTraits;
use tokio::{sync::broadcast, time::timeout};

#[tokio::test]
async fn get_known_peers() -> Result<()> {
    let (end_of_epoch_channel, _) =
        broadcast::channel::<(CommitteeWithNetworkMetadata, ProtocolVersion)>(100);
    let config = P2pConfig::default();
    let (UnstartedDiscovery { state, .. }, server) = Builder::new(end_of_epoch_channel.subscribe())
        .config(config)
        .build_internal();

    // Err when own_info not set
    server.get_known_peers(Request::new(())).await.unwrap_err();

    // Normal response with our_info
    let our_info = NodeInfo {
        peer_id: PeerId([9; 32]),
        addresses: Vec::new(),
        timestamp_ms: now_unix(),
    };
    state.write().unwrap().our_info = Some(our_info.clone());
    let response = server
        .get_known_peers(Request::new(()))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(response.own_info, our_info);
    assert!(response.known_peers.is_empty());

    // Normal response with some known peers
    let other_peer = NodeInfo {
        peer_id: PeerId([13; 32]),
        addresses: Vec::new(),
        timestamp_ms: now_unix(),
    };
    state
        .write()
        .unwrap()
        .known_peers
        .insert(other_peer.peer_id, other_peer.clone());
    let response = server
        .get_known_peers(Request::new(()))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(response.own_info, our_info);
    assert_eq!(response.known_peers, vec![other_peer]);

    Ok(())
}

#[tokio::test]
async fn make_connection_to_seed_peer() -> Result<()> {
    let (end_of_epoch_channel, _) =
        broadcast::channel::<(CommitteeWithNetworkMetadata, ProtocolVersion)>(100);
    let config = P2pConfig::default();
    let (builder, server) = Builder::new(end_of_epoch_channel.subscribe())
        .config(config)
        .build();
    let network_1 = build_network(|router| router.add_rpc_service(server));
    let (_event_loop_1, _handle_1) = builder.build(network_1.clone());

    let mut config = P2pConfig::default();
    config.seed_peers.push(SeedPeer {
        peer_id: None,
        address: format!("/dns/localhost/udp/{}", network_1.local_addr().port()).parse()?,
    });
    let (builder, server) = Builder::new(end_of_epoch_channel.subscribe())
        .config(config)
        .build();
    let network_2 = build_network(|router| router.add_rpc_service(server));
    let (mut event_loop_2, _handle_2) = builder.build(network_2.clone());

    let (mut subscriber_1, _) = network_1.subscribe()?;
    let (mut subscriber_2, _) = network_2.subscribe()?;

    event_loop_2.handle_tick(std::time::Instant::now(), now_unix());

    assert_eq!(
        subscriber_2.recv().await?,
        PeerEvent::NewPeer(network_1.peer_id())
    );
    assert_eq!(
        subscriber_1.recv().await?,
        PeerEvent::NewPeer(network_2.peer_id())
    );

    Ok(())
}

#[tokio::test]
async fn make_connection_to_seed_peer_with_peer_id() -> Result<()> {
    let (end_of_epoch_channel, _) =
        broadcast::channel::<(CommitteeWithNetworkMetadata, ProtocolVersion)>(100);
    let config = P2pConfig::default();
    let (builder, server) = Builder::new(end_of_epoch_channel.subscribe())
        .config(config)
        .build();
    let network_1 = build_network(|router| router.add_rpc_service(server));
    let (_event_loop_1, _handle_1) = builder.build(network_1.clone());

    let mut config = P2pConfig::default();
    config.seed_peers.push(SeedPeer {
        peer_id: Some(network_1.peer_id()),
        address: format!("/dns/localhost/udp/{}", network_1.local_addr().port()).parse()?,
    });
    let (builder, server) = Builder::new(end_of_epoch_channel.subscribe())
        .config(config)
        .build();
    let network_2 = build_network(|router| router.add_rpc_service(server));
    let (mut event_loop_2, _handle_2) = builder.build(network_2.clone());

    let (mut subscriber_1, _) = network_1.subscribe()?;
    let (mut subscriber_2, _) = network_2.subscribe()?;

    event_loop_2.handle_tick(std::time::Instant::now(), now_unix());

    assert_eq!(
        subscriber_2.recv().await?,
        PeerEvent::NewPeer(network_1.peer_id())
    );
    assert_eq!(
        subscriber_1.recv().await?,
        PeerEvent::NewPeer(network_2.peer_id())
    );

    Ok(())
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn three_nodes_can_connect_via_discovery() -> Result<()> {
    // Setup the peer that will be the seed for the other two
    let (end_of_epoch_channel, _) =
        broadcast::channel::<(CommitteeWithNetworkMetadata, ProtocolVersion)>(100);
    let config = P2pConfig::default();
    let (builder, server) = Builder::new(end_of_epoch_channel.subscribe())
        .config(config)
        .build();
    let network_1 = build_network(|router| router.add_rpc_service(server));
    let (event_loop_1, _handle_1) = builder.build(network_1.clone());

    let mut config = P2pConfig::default();
    config.seed_peers.push(SeedPeer {
        peer_id: Some(network_1.peer_id()),
        address: format!("/dns/localhost/udp/{}", network_1.local_addr().port()).parse()?,
    });
    let (builder, server) = Builder::new(end_of_epoch_channel.subscribe())
        .config(config.clone())
        .build();
    let network_2 = build_network(|router| router.add_rpc_service(server));
    let (mut event_loop_2, _handle_2) = builder.build(network_2.clone());
    // Set an external_address address for node 2 so that it can share its address
    event_loop_2.config.external_address =
        Some(format!("/dns/localhost/udp/{}", network_2.local_addr().port()).parse()?);

    let (builder, server) = Builder::new(end_of_epoch_channel.subscribe())
        .config(config)
        .build();
    let network_3 = build_network(|router| router.add_rpc_service(server));
    let (event_loop_3, _handle_3) = builder.build(network_3.clone());

    let (mut subscriber_1, _) = network_1.subscribe()?;
    let (mut subscriber_2, _) = network_2.subscribe()?;
    let (mut subscriber_3, _) = network_3.subscribe()?;

    // Start all the event loops
    tokio::spawn(event_loop_1.start());
    tokio::spawn(event_loop_2.start());
    tokio::spawn(event_loop_3.start());

    let peer_id_1 = network_1.peer_id();
    let peer_id_2 = network_2.peer_id();
    let peer_id_3 = network_3.peer_id();

    // Get two events from node and make sure they're all connected
    let peers_1 = [subscriber_1.recv().await?, subscriber_1.recv().await?]
        .into_iter()
        .map(unwrap_new_peer_event)
        .collect::<HashSet<_>>();
    assert!(peers_1.contains(&peer_id_2));
    assert!(peers_1.contains(&peer_id_3));

    let peers_2 = [subscriber_2.recv().await?, subscriber_2.recv().await?]
        .into_iter()
        .map(unwrap_new_peer_event)
        .collect::<HashSet<_>>();
    assert!(peers_2.contains(&peer_id_1));
    assert!(peers_2.contains(&peer_id_3));

    let peers_3 = [subscriber_3.recv().await?, subscriber_3.recv().await?]
        .into_iter()
        .map(unwrap_new_peer_event)
        .collect::<HashSet<_>>();
    assert!(peers_3.contains(&peer_id_1));
    assert!(peers_3.contains(&peer_id_2));

    Ok(())
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn peers_are_added_from_reocnfig_channel() -> Result<()> {
    let (end_of_epoch_channel_1, _) =
        broadcast::channel::<(CommitteeWithNetworkMetadata, ProtocolVersion)>(100);
    let config = P2pConfig::default();
    let (builder, server) = Builder::new(end_of_epoch_channel_1.subscribe())
        .config(config.clone())
        .build();
    let network_1 = build_network(|router| router.add_rpc_service(server));
    let (event_loop_1, _handle_1) = builder.build(network_1.clone());

    let (end_of_epoch_channel_2, _) =
        broadcast::channel::<(CommitteeWithNetworkMetadata, ProtocolVersion)>(100);
    let (builder, server) = Builder::new(end_of_epoch_channel_2.subscribe())
        .config(config.clone())
        .build();
    let network_2 = build_network(|router| router.add_rpc_service(server));
    let (event_loop_2, _handle_2) = builder.build(network_2.clone());

    let authority_name_2 = get_authority_pub_key_bytes();

    let (mut subscriber_1, _) = network_1.subscribe()?;
    let (mut subscriber_2, _) = network_2.subscribe()?;

    // Start all the event loops
    tokio::spawn(event_loop_1.start());
    tokio::spawn(event_loop_2.start());

    let peer_id_1 = network_1.peer_id();
    let peer_id_2 = network_2.peer_id();

    // At this moment peer 1 and peer 2 are not connected.
    let mut futures = FuturesUnordered::new();
    futures.push(timeout(Duration::from_secs(2), subscriber_1.recv()));
    futures.push(timeout(Duration::from_secs(2), subscriber_2.recv()));
    while let Some(result) = futures.next().await {
        let _elapse = result.unwrap_err();
    }

    let (mut subscriber_1, _) = network_1.subscribe()?;
    let (mut subscriber_2, _) = network_2.subscribe()?;

    // We send peer 1 a new committee info (peer 2) from the reconfig channel.
    let committee = Committee::new(1, BTreeMap::from([(authority_name_2, 1)])).unwrap();
    let peer_2_network_pubkey =
        Ed25519PublicKey(ed25519_consensus::VerificationKey::try_from(peer_id_2.0).unwrap());
    end_of_epoch_channel_1
        .send((
            CommitteeWithNetworkMetadata {
                committee,
                network_metadata: BTreeMap::from([(
                    authority_name_2,
                    NetworkMetadata {
                        network_pubkey: peer_2_network_pubkey,
                        // network_address does not matter here
                        network_address: format!(
                            "/dns/localhost/udp/{}",
                            network_2.local_addr().port()
                        )
                        .parse()
                        .unwrap(),
                        p2p_address: format!(
                            "/dns/localhost/udp/{}",
                            network_2.local_addr().port()
                        )
                        .parse()
                        .unwrap(),
                    },
                )]),
            },
            ProtocolVersion::new(1),
        ))
        .unwrap();

    // Now peer 1 and peer 2 are connected.
    let new_peer_for_1 = unwrap_new_peer_event(subscriber_1.recv().await.unwrap());
    assert_eq!(new_peer_for_1, peer_id_2);
    let new_peer_for_2 = unwrap_new_peer_event(subscriber_2.recv().await.unwrap());
    assert_eq!(new_peer_for_2, peer_id_1);

    Ok(())
}

fn unwrap_new_peer_event(event: PeerEvent) -> PeerId {
    match event {
        PeerEvent::NewPeer(peer_id) => peer_id,
        e => panic!("unexpected event: {e:?}"),
    }
}

pub fn get_authority_pub_key_bytes() -> AuthorityPublicKeyBytes {
    let (_val0_addr, val0_kp) = get_authority_key_pair();
    AuthorityPublicKeyBytes::from(val0_kp.public())
}
