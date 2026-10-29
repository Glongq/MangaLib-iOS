# External video sources

## Source selection

Menu → Settings → Other sites contains one participation switch per source.
Enabled sources are grouped under Manga and Video. The bottom segmented control
selects the kind shown by both the combined catalog and the recommendation feed.
Rule34 and Rule34Video are video-only; existing sources remain in Manga. Selecting a kind does not
erase the other kind's source switches, likes, history, or bookmarks.

Changing a source switch activates combined external mode, even with one source.
There is no additional active-site checkbox. Choosing a Lib site in the main menu
still returns to that ecosystem without changing stored external preferences.
Legacy single-external-site routing is migrated to combined mode on launch.

## Rule34 retrieval

`Rule34Provider` uses the HTML and JSON shapes observed in the saved October 17
2026 capture:

- Catalog/search: `index.php?page=post&s=list&tags=video...`, with real `pid` links.
- Page jumps: the captured native page size is 42 posts.
- Detail: `index.php?page=post&s=view&id=...`; the video and poster URLs come from
  `video` / `source` elements. Static-image posts are rejected.
- Suggestions: `ac.rule34.xxx/autocomplete.php?q=...`, decoded as JSON despite
  the observed `text/html` content type.
- Categorized tags, artists, characters, source series and dates come from the
  detail HTML. The uploader is not substituted for an artist.

The provider always includes the `video` tag. It does not invent CDN filenames,
assume a hostname defines the media type, or use the unverified adjacent-post
helper. Favorites, comments and blacklist editing are not exposed as supported
account actions.

Catalog thumbnails are parsed from listing cards and cached separately from full
post metadata. Grid cells do not each request a video post page. The post is fetched
when opened or considered for the recommendation feed.

All Rule34 HTML, suggestion and vote requests share a start interval of 1.1 seconds.
HTTP 429 responses postpone the shared deadline, respect numeric or HTTP-date
`Retry-After` values and retry within a bounded request. Deferred feed candidates
and their cursors are retained; rate limits do not shrink inferred archive bounds.
The queue keeps draining pending candidates when a refill finishes below its buffer
threshold. CAPTCHA and rate-limit responses have source-specific error messages.

## Catalog filters

Rule34's filters use its documented search metatags: included tags (all/any),
excluded tags, content rating, uploader, minimum score, minimum dimensions and
sorting. The normal text query remains additive. Unsupported duration or upload-date
filters are not invented for this source. Reference:
https://rule34.xxx/index.php?page=help&topic=cheatsheet

Rule34Video uses separate structured filters and numeric entity IDs. Suggestions
are requested live from `tags_json.php`, `categories_json.php` and `models_json.php`;
the captured partial dictionary is not a limit on the searchable catalog. Empty
`items: ""` responses are normalized. Each entity can be included or excluded,
with independent all/any modes for tags, categories and artists. The remaining
fields cover type/source IDs, date presets/custom ISO dates, duration in seconds,
minimum quality, uploader verification and all captured ordering values. Sort
orders appear as individually selectable rows. Tag matching is labeled "At least
one" / "All together" and appears only for multiple included entities.

New optional persistence fields preserve previous filters and named presets.
Filters apply only to their own site; text search combines with them. Normal
catalog filters are independent of the recommendation feed's interests.

## Rule34Video retrieval

`Rule34VideoProvider` implements the saved manual capture and supplement from
October 17. KVS `get_block` responses are HTML. The provider retains the block ID,
`from`/`from_videos` variable and real next-page number in an opaque cursor.
Search routing mirrors the site's slug encoder. Mobile HTML does not contain the
desktop-only `js-open-popup` class: video links containing images identify cards
on both layouts. A positive reported total with no parseable cards is a parsing
error, except for requests beyond the reported last page. Listing cards supply lightweight
previews; stable numeric IDs resolve full metadata through `/popup-video/{id}/`.
Signed movie URLs are read only from the main `flashvars` configuration, excluding
advertisements and event-reporting pixels. 1080p is preferred to automatic 4K.
Captured requests confirm that supplied movie URLs redirect to the media CDN.

Suggestions are cached briefly; catalog, metadata and suggestions share a one-second
start interval and bounded HTTP 429 retries. Concurrent detail requests for one video
are coalesced. Preview/detail caches are bounded; expiring signed playback URLs are
cached for two minutes. Rate-limited recommendation candidates remain pending.
JSON and async-block requests include the captured `X-Requested-With` and Accept
headers. Omitting the former causes the account endpoint to return HTTP 403.
The integration does not import recorded account cookies, passwords or tokens.

## Rule34Video login

The Rule34Video source row provides sign-in, sign-out, status and revalidation.
A temporary isolated WKWebView loads the website's complete root document and
activates its own captured login link. `/login/` alone is a form fragment without
the AJAX handlers. The website retains password entry, CSRF submission, errors
and challenges. The app does not inspect password fields or replay a recording.

PHPSESSID exists before authentication. Cookie presence alone therefore never
confirms login: `tag_wiki.php?action=me` must return `status: ok` and
`me.logged_in: true`. Cookie changes trigger automatic checks; a Check login button
also handles session-only sign-ins without a changed persistent cookie. Only
confirmed first-party session/anti-bot cookies are kept in a separate versioned
Keychain entry. Network failures preserve the session; confirmed logout removes it.
Concurrent validation and cookie rotations cannot overwrite a newer session.

Native metadata requests attach session cookies only to the exact HTTPS origin.
The system cookie jar is disabled and credentials are removed on cross-origin
redirects, including redirects from signed movie URLs to the CDN. Video metadata
caches are scoped to the session revision; catalog, feed and detail views reload
on sign-in/sign-out, preventing reuse of another session's signed movie URLs.
Existing Rule34 and Pixiv authentication remain separate.

## Website login

The Rule34 row in Other sites has the same sign-in/sign-out placement as Pixiv.
It opens the real `index.php?page=account&s=login&code=00` form in a temporary,
isolated WKWebView. The website handles password entry and any CAPTCHA itself;
app code never reads or persists a password.

The successful browser capture confirmed a form POST with `user`, `pass` and
`submit`, a 302 redirect to the account home page, and `user_id` / `pass_hash`
cookies. No captured credential values are used by the app. It validates its own
cookies through the account page's Logout and matching My Profile links. A public
profile supplies the optional display name. A redirect or cookies alone do not
count as a completed login.

The confirmed session is stored as versioned cookie data in a Rule34-specific
Keychain entry. Rule34 HTML and upvote requests attach it only to the exact HTTPS
Rule34 origin; autocomplete, video CDNs, Lib and Pixiv never receive these cookies.
The transport disables the system cookie jar and removes credentials on redirects
outside that origin. Sign-out deletes the stored and in-memory session. Pending
validation cannot restore a session after sign-out. Reopening settings revalidates
the stored account; transient network failures preserve it with a retry action.
Local recommendation feedback remains independent of website authentication.

## Playback and feedback

Catalog and detail cards do not autoplay: playback opens only after tapping Watch.
The vertical recommendation feed immediately plays the selected video's native
AVPlayer surface while retaining local tag preferences,
likes/dislikes and bookmarks. Changing kind resets catalog identity and the feed's
source scope so image and video queues cannot be mixed.

`ExternalVideoResourceLoader` uses AVAssetResourceLoaderDelegate and URLSession
to forward byte-range requests with the source's Referer and User-Agent. Data is
passed directly to AVFoundation without accumulating a movie in app-owned memory.
Cancellation stops the corresponding HTTP task. Leaving a video, covering the
feed with another screen or backgrounding the app releases the asset and cancels
its transfers. Picture in Picture is disabled.

Only actual playback counts toward implicit feedback. Pauses, buffering and
offscreen cards do not accrue viewing time; seeks do not add skipped time. A weak
positive reading signal requires at least ten seconds and 20% watched. New optional
persisted fields keep older recommendation records readable. Explicit feedback
continues using the existing recommendation model and shared tag identities.

Liking a Rule34 item saves local feedback immediately, then attempts
`GET index.php?page=post&s=vote&id=...&type=up` separately with cache bypassed.
The website response is intentionally ignored. A network failure or rejected vote
does not display an error, undo the local like, or stop recommendation learning.
Unliking and disliking do not send website votes; no downvote contract was captured.

## Validation boundary

The device IPA is built locally. A native URLSession diagnostic confirmed successful
listing/detail responses followed by HTTP 429 during an unpaced burst. A simulator
UI check was prepared but canceled at the user's request before completion; no UI
test pass or complete playback validation is claimed. No live vote was performed.
CAPTCHA challenges, server-side vote rejection and device-specific playback remain
runtime conditions to check on the device.

For Rule34Video, native macOS URLSession diagnostics with the provider's iPhone
User-Agent confirmed 23 cards on both the first page and the next async block,
live tag suggestions, the account endpoint, full popup metadata and an HTTP 206
video/mp4 response with Content-Range from the CDN. The media probe canceled at
response headers; it did not download a movie. These checks do not constitute a
simulator UI pass or a completed on-device sign-in.
