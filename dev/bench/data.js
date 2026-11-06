window.BENCHMARK_DATA = {
  "lastUpdate": 1793928115060,
  "repoUrl": "https://github.com/GYWang1983/lua-leanjson",
  "entries": {
    "Benchmark": [
      {
        "commit": {
          "author": {
            "email": "gy.wang.1983@gmail.com",
            "name": "wanggy",
            "username": "GYWang1983"
          },
          "committer": {
            "email": "gy.wang.1983@gmail.com",
            "name": "wanggy",
            "username": "GYWang1983"
          },
          "distinct": true,
          "id": "aec40086846a7c1283498cae00310cb829fb8799",
          "message": "perf: reuse raw strings and encode JSON bytes in Rust",
          "timestamp": "2026-11-05T00:38:01-08:00",
          "tree_id": "5af6d00e30ac20e5728552844bd051c73d4deb11",
          "url": "https://github.com/GYWang1983/lua-leanjson/commit/aec40086846a7c1283498cae00310cb829fb8799"
        },
        "date": 1793928114437,
        "tool": "cargo",
        "benches": [
          {
            "name": "parse_eager/parse/small_api",
            "value": 1491,
            "range": "± 23",
            "unit": "ns/iter"
          },
          {
            "name": "parse_eager/parse/wide_object",
            "value": 5132,
            "range": "± 222",
            "unit": "ns/iter"
          },
          {
            "name": "parse_eager/parse/deep_nesting",
            "value": 3121,
            "range": "± 41",
            "unit": "ns/iter"
          },
          {
            "name": "parse_lazy/parse/small_api",
            "value": 547,
            "range": "± 31",
            "unit": "ns/iter"
          },
          {
            "name": "parse_lazy/parse/wide_object",
            "value": 1665,
            "range": "± 62",
            "unit": "ns/iter"
          },
          {
            "name": "parse_lazy/parse/deep_nesting",
            "value": 1413,
            "range": "± 59",
            "unit": "ns/iter"
          },
          {
            "name": "field_access/get_str/model",
            "value": 15,
            "range": "± 0",
            "unit": "ns/iter"
          },
          {
            "name": "field_access/get_f64/max_tokens",
            "value": 23,
            "range": "± 0",
            "unit": "ns/iter"
          },
          {
            "name": "field_access/get_str/nested",
            "value": 40,
            "range": "± 3",
            "unit": "ns/iter"
          }
        ]
      }
    ]
  }
}