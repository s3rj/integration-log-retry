# integration-log-retry

[![CI](https://github.com/s3rj/integration-log-retry/actions/workflows/ci.yml/badge.svg)](https://github.com/s3rj/integration-log-retry/actions/workflows/ci.yml)
![Apex on API 68.0](https://img.shields.io/badge/Apex-API%2068.0-00A1E0)
![52 tests, 93 to 100% coverage per class](https://img.shields.io/badge/tests-52%20passing%2C%2093--100%25%20per%20class-brightgreen)
[![MIT License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

A small framework for outbound Salesforce integrations that fail for boring reasons: a log record per unit of work, bulk-safe queueable execution, exponential-backoff retries, a Retry button for the rest, a Flow action so admins can wire integrations without new Apex, a platform event when work stops for good, and the housekeeping that keeps it all running a year later.

**At a glance**

- **The problem:** the ERP returns a 503 at 2 a.m., the trigger that called it swallowed the exception, and the order is never sent; nobody knows until finance reconciles.
- **What this is:** log first, then queue, then retry with a memory. Every callout is an `Integration_Log__c` record that carries its own job as JSON, so an attempt can be repeated from a queueable, a sweeper, or a button, hours later, without the original transaction.
- **Proof:** 52 tests, 93–100% coverage per class, validated in a Developer Edition org on API 68.0; a live job queued through the Flow action and a live Retry of a Failed log both logged HTTP 200 from postman-echo.com.
- **Try it:** deploy, assign `Integration_Log_Admin`, run `scripts/apex/schedule-jobs.apex` and `scripts/apex/enqueue-echo.apex`, then open the Integration Logs tab and press **Retry** on anything.
- **Where to look first:** `IntegrationRunner` (callouts first, then DML, then handlers), `IntegrationQueueable` (chunking, chaining, and the `Recovery` Finalizer), `IntegrationRetrySweeper` (due retries and stranded-work detection against `AsyncApexJob`), `IntegrationRetry` (what the button does), and `IntegrationRunnerTest` for the twelve ways an attempt can end.

## Why an org needs it

Most orgs call out from a trigger or a flow, catch the exception, and hope. When the ERP returns a 503 at 2 a.m., the order is silently never sent; nobody finds out until finance reconciles; and someone writes a "re-run the sync" script three months later. Each integration grows its own logging object, its own retry loop, and its own gaps. This project replaces that with one pattern: **log first, then queue, then retry with a memory.**

## What your org gets

- **Every outbound call is a record.** `Integration_Log__c` holds what was sent, what came back, how long it took, how many attempts, and why it stopped. The **Integration Logs** tab ships with **Needs Attention** (Failed and Handler Failed), **In Flight** (Queued and Retrying), and **Recent Logs** list views, so the support desk and the integration owner look at the same thing.
- **Failures retry themselves.** Timeouts, 429s, and 5xxs retry with exponential backoff; the policy is metadata per integration. A sweeper every ten minutes re-queues retries that are due and any Queued log whose queueable was aborted, purged from the flex queue, or lost to a deploy, so a lost job is never lost work.
- **A Retry button for everything else.** On the Integration Log record, **Retry** gives a Failed log exactly one more attempt now; for a Handler Failed log (the call succeeded, the post-processing threw) it re-runs the handler with the stored response without sending the request again; for a Retrying log it skips the wait. The same **Retry integration logs** action is available to any Flow.
- **Integrations from Flow, without new Apex.** The **Enqueue integration job** action takes a job class and a record: a record-triggered flow on Opportunity Closed Won can queue `SendOrderJob` with `{!$Record.Id}`, with the framework's retries and deduplication, and the admin never opens the Developer Console.
- **Alerting where you already have it.** When work stops for good, the framework publishes `Integration_Failure__e`. A platform-event-triggered flow posts to Slack, opens a case, or flags the record; no polling.
- **Housekeeping.** A daily purge deletes Succeeded logs after 30 days and failures after 90 (both per integration), so the object stays small and storage is not spent on last year's successful syncs.
- **Safe by construction.** Callouts run before any DML, so handlers can update records without "uncommitted work pending"; a dedup key means a trigger that fires twice sends once; a Finalizer catches the limit exception a try/catch cannot.

## How it works

```
IntegrationDispatcher.enqueue(job)            Flow: "Enqueue integration job"
   │  inserts Integration_Log__c (Queued) holding the job as JSON, records the queueable
   ▼
IntegrationQueueable (10 logs per execution)
   │  all callouts first ──► IntegrationRunner.run()
   │  then all DML: log outcome, publish failures, run job handlers
   ├─ leftovers ─────────────► chain immediately
   ├─ retryable failures ────► Retrying + Next Attempt At, chain with backoff (≤10 min)
   └─ exhausted / non-retryable ► Failed + Integration_Failure__e
IntegrationRetrySweeper (every 10 minutes)
   ├─ re-queues Retrying logs that are due, including any whose chain was lost
   └─ re-queues Queued logs older than 15 minutes whose queueable is gone
IntegrationRetry (Retry button / Flow action)
   ├─ Failed ──────────────► one more attempt, now
   ├─ Handler Failed ──────► re-run onSuccess with the stored response, no callout
   └─ Retrying ────────────► attempt now
IntegrationLogPurge (daily, 02:00)
      deletes Succeeded logs after Retention Days, failures after Failed Retention Days
```

- **The log is the unit of work.** `Integration_Log__c` stores the job's class and JSON state, so every attempt re-creates the job fresh (new tokens, current timestamps) and a retry survives the end of the transaction, the flex queue, and a lost chain. The log also records the queueable that holds it, which is how the sweeper tells a long queue from a dead job.
- **Callouts before DML.** A callout after DML in the same transaction fails with "uncommitted work pending", so the runner performs every callout in the batch first and only then writes logs and runs handlers, which are free to update records.
- **Retry policy lives in metadata.** `Integration_Setting__mdt` per integration: max attempts, base delay, retryable status codes, timeout, endpoint, retention. Callout exceptions (timeouts, DNS, TLS) always retry; a job can veto or force a retry for a specific response.
- **Exponential backoff** doubles the base delay after every failed attempt. The queueable delay is capped at the platform's ten minutes; later retries are the sweeper's job.
- **Idempotent enqueueing.** A job may return a dedup key; while a log with that key is active, enqueueing the same key returns that log instead of creating a second one.
- **Handler re-runs never re-send.** A Handler Failed log keeps the response it got. Fix the handler, press Retry, and the framework replays that response into `onSuccess`; the other system is not asked to create the order twice.
- **A Finalizer for the failures you cannot catch.** If a queueable dies from a limit exception, its transaction rolls back and nothing would be recorded. The attached `Recovery` finalizer counts the attempt, records the reason, and schedules the retry.

## Write a job

```apex
public with sharing class SendOrderJob extends IntegrationJobBase implements IntegrationRecordJob {
    public Id orderId;                 // public fields are serialized; keep them small

    public SendOrderJob() { super(); } // required: jobs are re-created from JSON
    public SendOrderJob(Id orderId) { this.orderId = orderId; }

    public void forRecord(Id recordId) { orderId = recordId; }           // what the Flow action calls

    public override String integrationName() { return 'ERP'; }          // Integration_Setting__mdt.ERP
    public override String operation() { return 'send-order'; }
    public override String dedupKey() { return 'order:' + orderId; }     // one active send per order
    public override Id recordId() { return orderId; }

    public override HttpRequest buildRequest(IntegrationSettings.Setting setting) {
        Order__c order = [SELECT Name, Total__c FROM Order__c WHERE Id = :orderId];
        HttpRequest request = new HttpRequest();
        request.setEndpoint(setting.endpoint + '/orders');             // e.g. callout:ERP/api/v1
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setBody(JSON.serialize(new Map<String, Object>{ 'name' => order.Name, 'total' => order.Total__c }));
        return request;
    }

    public override void onSuccess(HttpResponse response, Integration_Log__c log) {
        String erpId = (String) ((Map<String, Object>) JSON.deserializeUntyped(response.getBody())).get('id');
        update new Order__c(Id = orderId, ERP_Id__c = erpId, Last_Synced_At__c = System.now());
    }
}
```

Queue it from a trigger handler or anonymous Apex:

```apex
IntegrationDispatcher.enqueueAll(jobsForChangedOrders);   // one transaction, one queueable
```

Or from Flow, with no further code: add the **Enqueue integration job** action, set **Job class** to `SendOrderJob` and **Record Id** to `{!$Record.Id}`; **Parameters (JSON)** fills any other public field (`{"reason":"closed won"}`). Implementing `IntegrationRecordJob` (one method, `forRecord`) is what makes a job available to Flow.

Rules for jobs: a public no-argument constructor, JSON-serializable public fields, no DML in `buildRequest`, and an `onSuccess` that can be replayed (a Retry may run it again with the same response). Everything else is optional; `IntegrationJobBase` supplies defaults.

## Configure an integration

| `Integration_Setting__mdt` field | Meaning | Default |
|---|---|---|
| Developer Name | What `integrationName()` returns | |
| Max Attempts | Total attempts including the first | 3 |
| Base Delay (minutes) | Wait after the first failure; doubles each time | 1 |
| Retryable Status Codes | Comma-separated HTTP statuses that retry | 408, 429, 500, 502, 503, 504 |
| Timeout (seconds) | Applied to every attempt (max 120) | 30 |
| Endpoint | Handed to `buildRequest`; use a named credential (`callout:Name/path`) | |
| Active | Unchecked: `enqueue()` throws instead of queueing | checked |
| Retention Days | Succeeded logs are deleted this long after completion | 30 |
| Failed Retention Days | Failed and Handler Failed logs are deleted this long after completion | 90 |

Max attempts are copied onto each log when it is created, so changing a setting never alters work already in flight.

## Install and try it

```bash
sf project deploy start --target-org <org>
sf org assign permset --name Integration_Log_Admin --target-org <org>
sf apex run --target-org <org> --file scripts/apex/schedule-jobs.apex      # once per org: sweeper and purge
sf apex run --target-org <org> --file scripts/apex/enqueue-echo.apex       # a real callout to postman-echo.com
sf data query --target-org <org> --file scripts/soql/recent-logs.soql
```

The sample `EchoJob` and its `Echo` setting (plus a remote site for postman-echo.com) show a log going Queued to Succeeded against a live endpoint; `EchoJob` also implements `IntegrationRecordJob`, so you can try the Flow action on it. Delete them once you have real jobs.

## Operate it

| Status | Meaning | What Retry does |
|---|---|---|
| Queued | Logged, waiting for its first attempt | Nothing; the sweeper re-queues it if its queueable is gone |
| Retrying | A retryable failure; `Next Attempt At` says when | Attempts now |
| Succeeded | 2xx response; `onSuccess` ran | Nothing |
| Failed | Retries exhausted, a non-retryable response, or a job that could not be built; `Integration_Failure__e` published; `onFailure` ran | One more attempt, now |
| Handler Failed | The callout succeeded but `onSuccess` threw; the response is kept | Re-runs `onSuccess` with the stored response; no callout |

- **Alerting:** build a platform-event-triggered flow on `Integration_Failure__e` (integration, operation, log, record, attempts, error). Post to a channel, create a case, or set a flag on the record for the account team.
- **Pausing an integration:** uncheck **Active** on its setting; `enqueue()` refuses new work with a clear error while in-flight logs finish.
- **Watching the queue:** the **In Flight** list view, and `Async Job Id` on each log for **Setup > Apex Jobs**.

## Limits and trade-offs

- **One callout per log, ten logs per queueable execution.** Enough for most record-level integrations; a bulk endpoint needs a job that batches records itself.
- **No "Running" status.** Marking a log Running would be DML before the callout, which the platform forbids in one transaction. Duration and timestamps are written afterwards instead.
- **Handlers run after the whole batch's callouts.** `onSuccess` for log 1 runs after the callout for log 10, so handlers should not assume they run immediately.
- **The ten-minute enqueue cap** means a third retry at 4× base delay may wait for the sweeper. Schedule it.
- **Job payloads are stored as text** on the log (up to 128 KB). Keep IDs in the job and query the data in `buildRequest`; it keeps logs small and attempts current.
- **Inbound** webhooks are a different problem (signatures, replay protection, idempotent handlers); see the companion `hmac-webhook-receiver`.

## Development

```bash
scripts/validate.sh <org alias>                       # deploy and run all local tests with coverage
pmd check -d force-app -R pmd/ruleset.xml -f text     # static analysis, same ruleset as CI
```

Validated in a Developer Edition org on API 68.0: 52 tests, 93–100% coverage per class, a live `EchoJob` queued through the Flow action that logged HTTP 200 from postman-echo.com in 73 ms, and a live Retry of a Failed log that re-sent the request and succeeded.

Tests use `SequenceCalloutMock` (scripted status codes or exceptions) and `RecordingJob` (a job that can be told to misbehave). Logs are inserted before `Test.startTest()` and the runner is called once inside it, because a callout after DML in one transaction is an error, which is also why the runner never runs in the enqueueing transaction. Chaining is recorded rather than executed in tests, where only one queueable may run; the `Recovery` finalizer is exercised directly with a stub `FinalizerContext`; stranded-log detection is tested against real aborted and queued `AsyncApexJob` records.

## Part of a set

Three Salesforce patterns generalized from production work and rebuilt from scratch with tests and CI, plus a CLI for the schema side:

- [sandbox-data-mask](https://github.com/s3rj/sandbox-data-mask): the data in your sandboxes
- [integration-log-retry](https://github.com/s3rj/integration-log-retry): this project, outbound callouts that log, retry, and recover
- [hmac-webhook-receiver](https://github.com/s3rj/hmac-webhook-receiver): inbound webhooks that are verified, deduplicated, and reprocessable
- [flow-hardcoded-id-scanner](https://github.com/s3rj/flow-hardcoded-id-scanner): a CI gate that finds hard-coded record Ids in Flow and other metadata

More at [github.com/s3rj](https://github.com/s3rj).

## License

MIT
