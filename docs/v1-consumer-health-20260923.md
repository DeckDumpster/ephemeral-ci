# v1 consumer health check — 2026-09-23

Verification that consumers were green on v1 after the move from c5f737f to b39ea40.

## v1 move

| | SHA | Commit |
|-|-----|--------|
| Old | c5f737f | "Wait for the node to have room before cloning a runner" |
| New | b39ea40 | "advance-v1: give the interface guard a door (#18)" |

Advance v1 run: [35873381514](https://github.com/DeckDumpster/ephemeral-ci/actions/runs/35873381514) (2026-09-23T14:19)

## ephemeral-ci main CI at v1 commit

- Run [35884456561](https://github.com/DeckDumpster/ephemeral-ci/actions/runs/35884456561): **success** (2026-09-23T15:50:05Z)

## reap.yml green on main at v1 commit

- Run [35886720222](https://github.com/DeckDumpster/ephemeral-ci/actions/runs/35886720222): **success** (2026-09-23T16:08:58Z)

## First green consumer runs after the move

**pokedumpster** — run [35892280829](https://github.com/DeckDumpster/pokedumpster/actions/runs/35892280829) (2026-09-23T16:57:06Z):
provision ✓, gate ✓, teardown ✓

**deckdumpster** — run [35917126938](https://github.com/DeckDumpster/deckdumpster/actions/runs/35917126938) (2026-09-23T20:36:50Z):
provision ✓, gate ✓, teardown ✓
