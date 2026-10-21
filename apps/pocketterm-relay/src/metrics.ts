// Prometheus metrics in the text format: request durations by method and status
// code (the server's Apps dashboard), and pushes by platform and status. Counts
// only: no label ever carries a token, an address or anything from a body.

const buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10];

type Series = { counts: number[]; sum: number; count: number };

export class Metrics {
  readonly #durations = new Map<string, Series>();
  readonly #pushes = new Map<string, number>();

  /** A finished request: [method], its status [code] and how long it took. */
  observe(method: string, code: number, seconds: number) {
    const labels = `method="${method}",code="${code}"`;
    let s = this.#durations.get(labels);
    if (!s) this.#durations.set(labels, s = { counts: buckets.map(() => 0), sum: 0, count: 0 });
    buckets.forEach((le, i) => {
      if (seconds <= le) s.counts[i]++;
    });
    s.sum += seconds;
    s.count++;
  }

  /** A push the relay answered with [code] for a phone on [platform]. */
  push(platform: string, code: number) {
    const labels = `platform="${platform}",code="${code}"`;
    this.#pushes.set(labels, (this.#pushes.get(labels) ?? 0) + 1);
  }

  /** Everything, in Prometheus's text exposition format. */
  text(): string {
    const out = [
      "# HELP http_request_duration_seconds HTTP request duration in seconds",
      "# TYPE http_request_duration_seconds histogram",
    ];
    for (const [labels, s] of this.#durations) {
      buckets.forEach((le, i) => out.push(`http_request_duration_seconds_bucket{${labels},le="${le}"} ${s.counts[i]}`));
      out.push(`http_request_duration_seconds_bucket{${labels},le="+Inf"} ${s.count}`);
      out.push(`http_request_duration_seconds_sum{${labels}} ${s.sum}`);
      out.push(`http_request_duration_seconds_count{${labels}} ${s.count}`);
    }
    out.push(
      "# HELP relay_pushes_total Pushes by phone platform and the relay's answer",
      "# TYPE relay_pushes_total counter",
    );
    for (const [labels, n] of this.#pushes) out.push(`relay_pushes_total{${labels}} ${n}`);
    return out.join("\n") + "\n";
  }
}
