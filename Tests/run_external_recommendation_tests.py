#!/usr/bin/env python3
"""Run real recommendation logic with deterministic sources, without Xcode or ML Kit."""

from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="mangalib-recommendation-tests-") as temporary:
    workspace = Path(temporary)
    engine = root / "App/ExternalSites/ExternalRecommendationEngine.swift"
    executable = workspace / "engine-tests"
    cache = workspace / "module-cache"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-module-cache-path", str(cache),
        str(engine), str(root / "Tests/ExternalRecommendationEngineTests.swift"),
        "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)

    # Use the actual shared models, protocol and default methods; fixtures supply only the registry.
    provider = root / "App/ExternalSites/ExternalSiteProvider.swift"
    protocol = workspace / "ExternalSiteProvider.swift"
    protocol.write_text(provider.read_text().split("enum ExternalSiteRegistry {", 1)[0])
    executable = workspace / "feed-tests"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-module-cache-path", str(cache),
        str(root / "App/ExternalSites/ExternalSite.swift"), str(protocol), str(engine),
        str(root / "App/ExternalSites/ExternalRecommendationStore.swift"),
        str(root / "App/ExternalSites/ExternalRecommendationFeedModel.swift"),
        str(root / "Tests/ExternalRecommendationFeedTests.swift"),
        "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
