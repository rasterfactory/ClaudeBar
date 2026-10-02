function read(response, context) {
    const body = response.json;
    const left = (used,limit) => Math.max(0,Math.min(100,(limit-used)/limit*100));
    return {quotas:[
        {type:"session",percentRemaining:left(body.fiveHourCost,12),resetsAt:body.fiveHourReset,windowSeconds:18000},
        {type:"weekly",percentRemaining:left(body.weeklyCost,30),resetsAt:body.weekEnd,windowSeconds:604800},
        {type:"time",name:"Monthly",percentRemaining:left(body.monthlyCost,60),resetsAt:body.monthEnd,windowSeconds:2592000}
    ]};
}
