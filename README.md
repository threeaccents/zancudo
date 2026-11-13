# zancudo

An MQTT 3.1.1 broker written in Zig, built on Linux epoll.

The goal is a respectable broker, not a bulletproof one: correct for the
common flows of the spec, without TLS, clustering or MQTT 5.

## Roadmap

### Connection

- [x] CONNECT / CONNACK with return codes
- [x] Generated client ID for an empty one (clean session only)
- [x] Takeover: a second CONNECT with the same client ID closes the first
- [x] PINGREQ / PINGRESP
- [x] DISCONNECT
- [x] Keep-alive: close a client silent for 1.5x its keep-alive
- [ ] Will message: store on CONNECT, publish on abnormal close, drop on DISCONNECT
- [ ] Packets larger than the 16KB input buffer

### Subscriptions

- [x] SUBSCRIBE / SUBACK
- [x] Topic trie with `+` and `#` wildcards
- [x] `$` topics don't match wildcards at the first level
- [ ] UNSUBSCRIBE / UNSUBACK
- [ ] SUBACK failure code (0x80) for an invalid filter instead of closing the client

### Publish

- [x] Route PUBLISH to matching subscribers
- [ ] Reject wildcards in PUBLISH topic names
- [ ] Deliver at min(publish QoS, subscription QoS)
- [ ] Clear DUP and RETAIN on messages forwarded to subscribers
- [ ] Retained messages: keep the last one per topic, empty payload clears it
- [ ] Send retained messages on SUBSCRIBE

### QoS 1

- [ ] PUBACK to the publisher
- [ ] Handle PUBACK from a subscriber and free its inflight slot
- [ ] Move queued messages into inflight when a slot frees up

### QoS 2

- [ ] Inbound: PUBREC, PUBREL, PUBCOMP, no duplicate delivery
- [ ] Outbound: PUBREC, PUBREL, PUBCOMP

### Sessions

- [x] Clean and persistent sessions
- [x] Session present flag in CONNACK
- [x] Queue messages for offline clients
- [ ] Resend unacked messages with DUP=1 on resume
- [ ] Keep a queued message when its send fails
- [ ] Draining the queue respects the inflight limit

### Bugs and cleanup

- [ ] `conns` key dangles after a takeover (Broker.appendConn)
- [ ] Accept error paths don't undo earlier steps (Server.handleSocketEv)
- [ ] Broker.deinit frees sessions, conns and subscriptions
- [ ] Shut down cleanly on SIGINT / SIGTERM

### Tests

- [ ] Session tests use real topics and payloads, and valid packets
- [ ] drainQueuedMsgs tests
- [ ] End-to-end test against a real client (mosquitto_pub / mosquitto_sub)

### Later

- [ ] Persist sessions and queues across restarts (Fqueue)
- [ ] Bitcask-inspired KV store for inflight messages
- [ ] MQTT over WebSocket
- [ ] Username / password auth
