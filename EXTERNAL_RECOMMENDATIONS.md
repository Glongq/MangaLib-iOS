# External feed recommendation learning

The external-site feed uses local metadata and user feedback. No server, image analysis,
ML SDK or ordinary-reader telemetry is involved. `ExternalRecommendationRankingWorker`
builds the model and ranks candidates outside the main actor. SwiftUI receives the queue.

## Data and compatibility

- Existing profile, shared tag identities, bookmarks and history remain durable data.
- `external_recommendation_learning_v1` stores a versioned neutral metadata corpus,
  up to 2,000 qualified presentation records, and stable interest centers separately.
- Candidate provenance is optional in saved discovery queues. Old queues keep their
  native search IDs, opaque resolve keys and pagination cursors. Missing provenance
  never generates historical channel rewards.
- A presentation UUID identifies one visit, including pauses for sheets/backgrounding.
  Flushes update its maximum visible time and distinct read-page count. Only a loaded,
  selected page starts timing; neighbor preloads do not.
- Profile revision, learning/corpus revision and algorithm version invalidate the
  worker cache. Cancelled calculations are not cached. Stale results are discarded.
  The displayed prefix keeps its positions and original selected channels.

## Neutral corpus and IDF

The third request in each search packet reserves a general-catalog lane, rotating
sites and retrieval depths. Up to three of nine existing metadata slots hydrate neutral
candidates; unused capacity serves available candidates. Metadata hydration and listing
requests keep the existing maximum of three concurrent requests. Known neutral results
are sampled before feedback exclusions; likes alone never enter the corpus.

Each site/observed-age bucket retains the 64 smallest stable document hashes. Native
IDs are deduplicated across buckets when computing frequencies. Per-site document
frequencies contribute equally, using their mean document frequency and effective
sample size in `1 + log((N + 1) / (df + 1))`, clamped to 1...2. The correction is off
through 50 examples and ramps linearly to full weight at 200. This estimates the
available sample, not the full catalogs. Unobserved tags default to 1.

IDF weights matching tags and unit vectors. It cannot create positive affinity for
an unrelated rare tag. An explicitly preferred common tag retains its positive floor.

## Training examples and interactions

Exact metadata copies share one example; the latest current explicit vote wins,
falling back to a bookmark when no vote exists. Removing or replacing a vote rebuilds
all derived contributions from current facts. Explicit facts are not pruned to impose
the training budget.

- Up to 512 recent explicit works: like/bookmark target 1, dislike target 0, weight 1.
- Up to 256 reading examples: target 1, weight 0.2, at least 10 visible seconds and
  either 20% of actual pages or three distinct pages read. A page needs 1.2 visible
  seconds to count as read. Separate visits cannot combine partial metrics to qualify.
- A quick swipe is not a negative tag-training example.

Sparse logistic regression includes normalized tag/author controls, tag-tag pairs and
author-tag pairs. Shared tags cross sites; author identifiers remain source-specific.
Feature expansion is bounded to 32 distinct tags and eight authors per work. Pairs need
support from three different works; at most 2,048 supported pairs survive. Training
uses ten deterministically shuffled SGD passes at step 0.05, with lazy global L2 decay:
0.001 for singles and 0.01 for pairs. Only the pair block changes the existing score,
through `0.6 * tanh(pairLogit)`. It remains disabled until there are 20 explicit works,
including at least three positive and three negative examples.

## Multiple interests

Positive works form IDF-weighted unit tag vectors. Weighted spherical k-means uses
deterministic farthest-first seeds, up to six centers, and five refinement passes.
Explicit examples weigh 1 and qualifying reading weighs 0.2. Centers retain previous
IDs when cosine similarity is at least 0.65, with one-to-one matching.

Scoring uses the best-matching direction, including preferred-tag coverage inside that
direction. Stable interest scoring and the last 20 qualified presentations mix 85/15.
Explicit favorite tags rotate independently of the six-center limit. Dedicated author
retrieval slots remain available and inherit the direction of positively rated works.
Creator/tag/source diversity penalties and the existing catalog age mix stay soft.

## Search channels and Thompson Sampling

A semantic channel combines strategy (single tag, tag pair, author, catalog or popular)
and interest ID. Native query variants, URLs and pagination pages do not become arms.
Each arm starts at Beta(2, 2); Gamma-derived Beta samples choose among available arms,
both for retrieval and for the next queue position. Native source/depth rotation remains
in retrieval. Within a selected arm, the common score, relevance floor and diversity
penalties choose the title. An unavailable arm never consumes a feed position.

General discovery probability ranges from 5% to 20% with posterior uncertainty;
there is no fixed fifth position. Cold starts fall back to preferred tags and catalog
results. A title found through several searches earns a result only for its selected
origin, after it is actually shown. Queue membership alone earns nothing.

Results are recomputed from the presentation ledger and current facts:

- Like/bookmark adds one success; dislike adds one failure, once per exact work.
- Qualified reading adds 0.2 success, once per work when no explicit fact supersedes it.
- A loaded visit lasting at least two seconds without interest adds 0.1 failure to its
  channel only; it does not dislike the title's tags.
- The explicit result belongs to the latest loaded visit preceding the explicit action.
  Later revisits do not renew that result. Removing/changing feedback replaces its
  contribution; a qualifying reading event may still supply its own weak contribution.
- Weights halve every 30 days. Network errors, empty searches and unloaded pages
  supply no negative outcome.

## Validation scope for this change

Only Swift parsing and `git diff --check` are run, as requested. Device behavior,
runtime performance, recommendation quality and network-source availability require
subsequent device observation; no build, tests or simulator run is part of this batch.
