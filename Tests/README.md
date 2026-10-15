Run the standalone recommendation tests on macOS:

```sh
python3 Tests/run_external_recommendation_tests.py
```

The engine tests cover vote reversal, explicit negatives, creator identities, namespaces,
cross-site duplicates, exploration, viewing signals, persistence and bounded history.
The feed tests run the production store and queue against deterministic providers,
covering targeted retrieval, pagination, partial-source failure, canceled responses,
lightweight gallery previews and lazy full-page loading. They make no network requests.

The initial signal weights are like +4, bookmark +3, dislike -5 (overriding implicit
positives), reading multiple pages up to +1.5, loaded foreground dwell up to +0.5,
and a quick skip -0.2. These are starting parameters, not measured universal optima.
Feature evidence is normalized and confidence-smoothed; weights are not added directly
to every matching candidate. Every fifth position favors unfamiliar interests, while
still respecting explicit exclusions and recent impressions. Profiles stay on device.
