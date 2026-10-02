// Only computes argv and window bounds. The generic worker executes the CLI.
const rows = `SELECT
  CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS t,
  CAST(json_extract(data, '$.cost') AS REAL) AS cost
FROM message
WHERE json_valid(data)
  AND json_extract(data, '$.providerID') = 'opencode-go'
  AND json_extract(data, '$.role') = 'assistant'
  AND json_type(data, '$.cost') IN ('integer', 'real')`;
function addMonth(date, count) {
    const year = date.getUTCFullYear(), month = date.getUTCMonth()+count;
    const last = new Date(Date.UTC(year,month+1,0)).getUTCDate();
    return new Date(Date.UTC(year,month,Math.min(date.getUTCDate(),last),date.getUTCHours(),date.getUTCMinutes(),date.getUTCSeconds()));
}
function bounds(now, anchor) {
    // Calendar.date(from:) normalizes an absent anchor day; adding a month
    // clamps it. Preserve the legacy Calendar behavior, including month ends.
    let start = new Date(Date.UTC(now.getUTCFullYear(),now.getUTCMonth(),anchor.getUTCDate(),anchor.getUTCHours(),anchor.getUTCMinutes(),anchor.getUTCSeconds()));
    if (start > now) start = addMonth(start,-1);
    return [start,addMonth(start,1)];
}
function next(responses, context) {
    const now = new Date(context.now*1000);
    const week = new Date(Date.UTC(now.getUTCFullYear(),now.getUTCMonth(),now.getUTCDate()));
    week.setUTCDate(week.getUTCDate()-(week.getUTCDay()+6)%7);
    const five = Math.trunc(now.getTime()-18000000);
    if (!responses.length) {
        const sql = `SELECT
  COALESCE(SUM(CASE WHEN t >= ${five} THEN cost ELSE 0 END), 0) AS five_hour_cost,
  COALESCE(SUM(CASE WHEN t >= ${week.getTime()} THEN cost ELSE 0 END), 0) AS weekly_cost,
  MIN(CASE WHEN t >= ${five} THEN t ELSE NULL END) AS five_hour_oldest_ms,
  MIN(t) AS anchor_ms
FROM (${rows})`;
        return {args:["db",sql,"--format","json"]};
    }
    const primaryRows = JSON.parse(responses[0]);
    const primary = Array.isArray(primaryRows) ? primaryRows[0] : null;
    if (!primary || typeof primary.five_hour_cost !== "number" || typeof primary.weekly_cost !== "number"
        || (primary.anchor_ms != null && !Number.isInteger(primary.anchor_ms))
        || (primary.five_hour_oldest_ms != null && !Number.isInteger(primary.five_hour_oldest_ms)))
        return {error:{parseFailed:"No primary window data"}};
    const month = primary.anchor_ms != null ? bounds(now,new Date(primary.anchor_ms)) : [now,new Date(now.getTime()+30*86400000)];
    if (primary.anchor_ms != null && responses.length === 1) {
        return {args:["db",`SELECT COALESCE(SUM(cost), 0) AS monthly_cost
FROM (${rows})
WHERE t >= ${month[0].getTime()} AND t < ${month[1].getTime()}`,"--format","json"]};
    }
    let monthly = 0;
    if (primary.anchor_ms != null) {
        const values = JSON.parse(responses[1]);
        if (!Array.isArray(values) || (values.length && typeof values[0].monthly_cost !== "number"))
            return {error:{parseFailed:"Invalid monthly cost"}};
        monthly = values.length ? values[0].monthly_cost : 0;
    }
    return {done:{fiveHourCost:primary.five_hour_cost,weeklyCost:primary.weekly_cost,monthlyCost:monthly,
        fiveHourReset:(primary.five_hour_oldest_ms != null ? primary.five_hour_oldest_ms/1000 : context.now)+18000,
        weekEnd:week.getTime()/1000+604800,monthEnd:month[1].getTime()/1000}};
}
