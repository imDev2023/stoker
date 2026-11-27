import { and, eq, isNull, sql } from "drizzle-orm";
import type { JobName, JobRun } from "@launchpad/contract";
import { jobLocks, jobRuns, operatorAlerts, type Db } from "@launchpad/db";

/** A Cron Trigger runs for at most 15 minutes, so a lease that long outlives any run whose Worker is still alive. */
const LEASE_SECONDS = 15 * 60;

/**
 * Runs one scheduled job and keeps a record of the run for the operator: when it started and ended, what it reports
 * doing, and why it failed. With `exclusive`, the run first takes the job's lease and is skipped if another run holds it,
 * so a Cron Trigger and a manual run never act at the same time. A failure is recorded and then thrown again.
 */
export async function runJob<T>(db: Db, job: JobName, work: () => Promise<T>, opts: { exclusive?: boolean } = {}): Promise<JobRun> {
  const id = crypto.randomUUID();
  if (opts.exclusive && !(await takeLease(db, job, id))) {
    const [skipped] = await db.insert(jobRuns).values({ id, job, status: "skipped", finishedAt: sql`now()` }).returning();
    return toJobRun(skipped!);
  }
  await db.insert(jobRuns).values({ id, job, status: "running" });
  try {
    const summary = await work();
    const [done] = await db
      .update(jobRuns)
      .set({ status: "succeeded", finishedAt: sql`now()`, summary: summary ?? null })
      .where(eq(jobRuns.id, id))
      .returning();
    // A job that runs again is no longer failing: its alert, if any, is over.
    await db
      .update(operatorAlerts)
      .set({ resolvedAt: sql`now()` })
      .where(and(eq(operatorAlerts.kind, "job_failed"), eq(operatorAlerts.subject, job), isNull(operatorAlerts.resolvedAt)));
    return toJobRun(done!);
  } catch (e) {
    const failure = e instanceof JobFailure ? e : null;
    const message = (e as Error).message;
    await db
      .update(jobRuns)
      .set({ status: "failed", finishedAt: sql`now()`, error: message, summary: failure?.summary ?? null })
      .where(eq(jobRuns.id, id));
    // One open alert per job, raised on the first failure and kept current with the latest one; resolved by a success.
    await db
      .insert(operatorAlerts)
      .values({ kind: "job_failed", subject: job, message: `The ${job} job failed: ${message}` })
      .onConflictDoUpdate({
        target: [operatorAlerts.kind, operatorAlerts.subject],
        set: {
          message: sql`excluded.message`,
          raisedAt: sql`case when ${operatorAlerts.resolvedAt} is null then ${operatorAlerts.raisedAt} else now() end`,
          notifiedAt: sql`case when ${operatorAlerts.resolvedAt} is null then ${operatorAlerts.notifiedAt} else null end`,
          resolvedAt: sql`null`,
        },
      });
    throw e;
  } finally {
    if (opts.exclusive) await releaseLease(db, job, id);
  }
}

/** Takes a job's lease for one run of it; false when another run holds it and it has not run out. */
async function takeLease(db: Db, job: JobName, runId: string) {
  const [lease] = await db
    .insert(jobLocks)
    .values({ job, runId, expiresAt: sql`now() + make_interval(secs => ${LEASE_SECONDS})` })
    .onConflictDoUpdate({
      target: jobLocks.job,
      set: { runId: sql`excluded.run_id`, expiresAt: sql`excluded.expires_at` },
      setWhere: sql`${jobLocks.expiresAt} < now()`,
    })
    .returning({ runId: jobLocks.runId });
  return lease !== undefined;
}

const releaseLease = (db: Db, job: JobName, runId: string) => db.delete(jobLocks).where(and(eq(jobLocks.job, job), eq(jobLocks.runId, runId)));

/**
 * Does `work` while holding a job's lease, with no run recorded: for work that is not the job but must never act beside
 * it (the operator's replay of an EVM chain beside its Indexer, #279). Null when a run holds the lease.
 */
export async function withLease<T>(db: Db, job: JobName, work: () => Promise<T>): Promise<{ done: T } | null> {
  const id = crypto.randomUUID();
  if (!(await takeLease(db, job, id))) return null;
  try {
    return { done: await work() };
  } finally {
    await releaseLease(db, job, id);
  }
}

/** A job that did part of its work before failing, so the run's record keeps what it did alongside why it failed. */
export class JobFailure extends Error {
  constructor(message: string, readonly summary: unknown) {
    super(message);
  }
}

export function toJobRun(r: typeof jobRuns.$inferSelect): JobRun {
  return {
    id: r.id,
    job: r.job as JobName,
    status: r.status,
    startedAt: r.startedAt.toISOString(),
    finishedAt: r.finishedAt?.toISOString() ?? null,
    summary: r.summary ?? null,
    error: r.error,
  };
}
