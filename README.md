# Zancudo

[![test](https://github.com/threeaccents/zancudo/actions/workflows/test.yml/badge.svg)](https://github.com/threeaccents/zancudo/actions/workflows/test.yml)

An MQTT 3.1.1 broker written in Zig.

I started this project mainly to learn Zig and to stay sane in the age of AI. All the code is written with my bare hands (I know what a psycho).
I haven't been 100% AI free though. I used it to better understand the MQTT protocol and generate the roadmap you see in this readme.

I'm using this broker for my farm. This is not meant to be a bullet proof mqtt broker more like a fun side project.
Now that I've gotten decently far I do want to finish implementing the 3.1.1 protocol. Perhaps even start implementing 
MQTT 5.

## Roadmap

### Connection

- [x] CONNECT / CONNACK with return codes
- [x] Generated client ID for an empty one (clean session only)
- [x] Takeover: a second CONNECT with the same client ID closes the first
- [x] PINGREQ / PINGRESP
- [x] DISCONNECT
- [x] Keep-alive: close a client silent for 1.5x its keep-alive
- [x] Will message: store on CONNECT, publish on abnormal close, drop on DISCONNECT
- [x] Reject a CONNECT whose will topic is empty or has wildcards
- [ ] Packets larger than the 16KB input buffer

### Subscriptions

- [x] SUBSCRIBE / SUBACK
- [x] Topic trie with `+` and `#` wildcards
- [x] `$` topics don't match wildcards at the first level
- [x] UNSUBSCRIBE / UNSUBACK
- [x] SUBACK failure code (0x80) for an invalid filter instead of closing the client

### Publish

- [x] Route PUBLISH to matching subscribers
- [x] Reject wildcards in PUBLISH topic names
- [x] Deliver at min(publish QoS, subscription QoS)
- [x] Clear DUP and RETAIN on messages forwarded to subscribers
- [x] Retained messages: keep the last one per topic, empty payload clears it
- [x] A will with Will Retain set becomes its topic's retained message
- [x] Send retained messages on SUBSCRIBE

### QoS 1

- [x] PUBACK to the publisher
- [x] Handle PUBACK from a subscriber and free its inflight slot
- [x] Move queued messages into inflight when a slot frees up

### QoS 2

- [x] Inbound: PUBREC, PUBREL, PUBCOMP, no duplicate delivery
- [x] Outbound: PUBREC, PUBREL, PUBCOMP

### Sessions

- [x] Clean and persistent sessions
- [x] Session present flag in CONNACK
- [x] Queue messages for offline clients
- [x] Resend unacked messages with DUP=1 on resume
- [x] Keep a queued message when its send fails


### Tests

- [ ] Pass Paho 3.1.1 test suite

### Later

- [ ] Persist sessions and queues across restarts (Fqueue)
- [ ] Bitcask-inspired KV store for inflight messages
- [ ] Username / password auth
