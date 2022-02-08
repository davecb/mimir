{
  local memberlistConfig = {
    'memberlist.abort-if-join-fails': false,
    'memberlist.bind-port': gossipRingPort,
    'memberlist.join': 'gossip-ring.%s.svc.cluster.local:%d' % [$._config.namespace, gossipRingPort],
  },

  local setupGossipRing(prefix='') = if $._config.multikv_migration_enabled then {
    ['%sring.store' % prefix]: 'multi',
    // don't remove consul.hostname, it may still be needed.
  } else {
    ['%sring.store' % prefix]: 'memberlist',
    ['%sconsul.hostname' % prefix]: null,
  },

  _config+:: {
    // Migrating from consul to memberlist is a multi-step process:
    // 1) Enable multikv_migration_enabled, with primary=consul, secondary=memberlist, and multikv_mirror_enabled=false, restart components.
    // 2) Set multikv_mirror_enabled=true. This doesn't require restart.
    // 3) Swap multikv_primary and multikv_secondary, ie. multikv_primary=memberlist, multikv_secondary=consul. This doesn't require restart.
    // 4) Set multikv_migration_enabled=false. This requires restart, but components will now use only memberlist.
    multikv_migration_enabled: false,
    multikv_primary: 'consul',
    multikv_secondary: 'memberlist',
    multikv_mirror_enabled: false,

    // Use memberlist only. This works fine on already-migrated clusters.
    // To do a migration from Consul to memberlist, multi kv storage needs to be used (See below).
    ingesterRingClientConfig+: setupGossipRing('') + memberlistConfig,  // ring.store, ring.consul.hostname.

    // store-gateway.sharding-ring.store and store-gateway.sharding-ring.consul.hostname
    queryBlocksStorageConfig+:: setupGossipRing('store-gateway.sharding-') + memberlistConfig,

    // When doing migration via multi KV store, this section can be used
    // to configure runtime parameters of multi KV store
    multi_kv_config: if !$._config.multikv_migration_enabled then {} else {
      primary: $._config.multikv_primary,
      secondary: $._config.multikv_secondary,
      mirror_enabled: $._config.multikv_mirror_enabled,
    },
  },

  distributor_args+: setupGossipRing('distributor.') + memberlistConfig,  // distributor.ring.store, distributor.ring.consul.hostname

  ruler_args+: setupGossipRing('ruler.') + memberlistConfig,  // ruler.ring.store, ruler.ring.consul.hostname

  compactor_args+: setupGossipRing('compactor.') + memberlistConfig,  // compactor.ring.store, compactor.ring.consul.hostname

  ingester_args+: {
    // wait longer to see LEAVING ingester in the gossiped ring, to avoid
    // auto-join without transfer from LEAVING ingester.
    'ingester.join-after': '60s',

    // Updating heartbeat is low-cost operation when using gossiped ring, we can
    // do it more often (gossiping will happen no matter what, we may as well send
    // recent timestamps).
    // It also helps other components to see more recent update in the ring.
    'ingester.heartbeat-period': '5s',
  },

  local gossipRingPort = 7946,

  local containerPort = $.core.v1.containerPort,
  local gossipPort = containerPort.newNamed(name='gossip-ring', containerPort=gossipRingPort),

  distributor_ports+:: [gossipPort],
  querier_ports+:: [gossipPort],
  ingester_ports+:: [gossipPort],

  distributor_deployment_labels+:: { [$._config.gossip_member_label]: 'true' },
  ingester_deployment_labels+:: { [$._config.gossip_member_label]: 'true' },
  querier_deployment_labels+:: { [$._config.gossip_member_label]: 'true' },

  // Headless service (= no assigned IP, DNS returns all targets instead) pointing to some
  // users of gossiped-ring. We use ingesters as seed nodes for joining gossip cluster.
  // During migration to gossip, it may be useful to use distributors instead, since they are restarted faster.
  gossip_ring_service:
    local service = $.core.v1.service;

    // backwards compatibility with ksonnet
    local servicePort =
      if std.objectHasAll($.core.v1, 'servicePort')
      then $.core.v1.servicePort
      else service.mixin.spec.portsType;

    local ports = [
      servicePort.newNamed('gossip-ring', gossipRingPort, gossipRingPort) +
      servicePort.withProtocol('TCP'),
    ];
    service.new(
      'gossip-ring',  // name
      { [$._config.gossip_member_label]: 'true' },  // point to all gossip members
      ports,
    ) + service.mixin.spec.withClusterIp('None'),  // headless service
}
