# Tests

Build the local image on EOS, then run the offline checks:

```sh
docker compose -f docker-compose.yml -f docker-compose.dev.yml build
tests/run.sh
```

Run the live hot-reload check only during a maintenance window:

```sh
RUN_LIVE=1 tests/run.sh
```
