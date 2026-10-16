Run the standalone recommendation tests on macOS:

```sh
python3 Tests/run_external_recommendation_tests.py
```

The engine tests cover vote reversal, explicit negatives, creator identities, namespaces,
cross-site duplicates, exploration, viewing signals, persistence and bounded history.
The feed tests run the production store and queue against deterministic providers,
covering targeted retrieval, pagination, partial-source failure, canceled responses,
lightweight gallery previews, lazy full-page loading and deferred queue updates during
interactive page transitions. Ranking runs on a dedicated actor. The tests make no network requests.

The initial signal weights are like +4, bookmark +3, dislike -5 (overriding implicit
positives), reading multiple pages up to +1.5, loaded foreground dwell up to +0.5,
and a quick skip -0.2. These are starting parameters, not measured universal optima.
Feature evidence is normalized and confidence-smoothed; weights are not added directly
to every matching candidate. Every fifth position favors unfamiliar interests, while
still respecting explicit exclusions and recent impressions. Profiles stay on device.

Run Hitomi CDN routing and shared-cache refresh checks:

```sh
python3 Tests/run_hitomi_routing_tests.py
python3 Tests/run_hitomi_routing_tests.py --har /path/to/capture.har
```

The optional HAR comparison checks generated full-size image URLs against the capture.
Tests use a local URLProtocol fixture and make no external network requests.
