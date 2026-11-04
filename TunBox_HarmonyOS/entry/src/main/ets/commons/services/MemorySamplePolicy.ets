export class MemorySample {
  sampledAt: number = 0;
  pssKb: number = 0;
}

export class MemorySamplePolicy {
  static bytes(text: string, now: number): number {
    try {
      const sample = JSON.parse(text) as MemorySample;
      const age = now - sample.sampledAt;
      if (!Number.isFinite(age) || age < -1000 || age > 15000 ||
        !Number.isFinite(sample.pssKb) || sample.pssKb <= 0) { return -1; }
      return sample.pssKb * 1024;
    } catch (_e) { return -1; }
  }
}
