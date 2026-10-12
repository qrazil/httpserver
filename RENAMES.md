# httpserver: what moved or was renamed

## 0.6.0: project layout

No change to the program, its flags or its behaviour. Paths changed, so anything
that calls a script by path (CI, a Makefile, notes) must follow.

| old | new |
|---|---|
| `scripts/test.sh` | `tests/test.sh` (the single entry point for the tests) |
| `scripts/test_static.sh` | `tests/test_static.sh` |
| `scripts/static_common.py`, `static_fixture.py`, `static_fuzz.py`, `static_oracle.py`, `static_policy.py`, `static_stream.py` | `tests/` (same names) |
| `scripts/https_client.m31` | `tests/https_client.m31` |

`scripts/` now holds only the build helpers: `build.sh` and `build_scaling.sh`.
The long description of the test suite moved from the README to `docs/testing.md`.
`bench/` is unchanged.

## 0.5.1: m31 0.4.0 layout and naming

| old | new |
|---|---|
| `fileserver.m31`, module `fileserver` | `HTTP_fileserver.m31`, module `HTTP_fileserver` |
| `import http;` | `import net.http;` |
| `import tlsserver;` | `import tls.tlsserver;` |
| `os.args()` | `os.arguments()` |
| `fs.is_dir` | `fs.is_directory` |
| `parsed.given(...)` | `parsed.is_given(...)` |
| `http.serve_conn` | `http.serve_connection` |
| `fileserver.valid_index` | `HTTP_fileserver.is_valid_index` |

The full list of standard-library renames is `docs/naming-decision.md` and
CHANGELOG.md in the m31 repository.
