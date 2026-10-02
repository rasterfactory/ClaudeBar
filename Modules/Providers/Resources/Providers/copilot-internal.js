function read(response, context) {
    let json;
    const failure=message=>({error:{parseFailed:'Failed to parse Copilot Internal API response: '+message}});
    try { json=JSON.parse(response.text); } catch(e) { return failure(e.message); }
    const object=v=>v && typeof v==='object' && !Array.isArray(v);
    const number=v=>typeof v==='number' && Number.isFinite(v);
    const integer=v=>number(v) && Number.isInteger(v);
    if(!object(json) || (json.copilot_plan!=null && typeof json.copilot_plan!=='string') || (json.quota_snapshots!=null && !object(json.quota_snapshots)))return failure('Invalid user response');
    // Match JSONDecoder.convertFromSnakeCase without rejecting camelCase fixtures.
    const choose=(o,snake,camel)=>o[snake]===undefined?o[camel]:o[snake];
    json.copilot_plan=choose(json,'copilot_plan','copilotPlan');
    json.quota_snapshots=choose(json,'quota_snapshots','quotaSnapshots');
    if([choose(json,'quota_reset_date','quotaResetDate'),choose(json,'quota_reset_date_utc','quotaResetDateUtc')].some(v=>v!=null && typeof v!=='string'))return failure('Invalid reset date');
    if((json.copilot_plan!=null && typeof json.copilot_plan!=='string') || (json.quota_snapshots!=null && !object(json.quota_snapshots)))return failure('Invalid user response');
    const snapshots=json.quota_snapshots||{},premium=choose(snapshots,'premium_interactions','premiumInteractions');
    if(object(premium)) {
        premium.overage_count=choose(premium,'overage_count','overageCount');
        premium.overage_permitted=choose(premium,'overage_permitted','overagePermitted');
        premium.percent_remaining=choose(premium,'percent_remaining','percentRemaining');
    }
    if(premium!=null && (!object(premium) || ['entitlement','remaining','overage_count'].some(k=>premium[k]!=null && !integer(premium[k])) || ['unlimited','overage_permitted'].some(k=>premium[k]!=null && typeof premium[k]!=='boolean') || (premium.percent_remaining!=null && !number(premium.percent_remaining))))return failure('Invalid premium interactions');
    const plan=json.copilot_plan==null?'unknown':json.copilot_plan;
    let remaining=100,text='No AI credits quota';
    if(premium!=null && premium.unlimited===true)text='Unlimited AI credits';
    else if(premium!=null) {
        const entitlement=premium.entitlement==null?0:premium.entitlement,left=premium.remaining==null?0:premium.remaining;
        remaining=premium.percent_remaining==null?100:premium.percent_remaining;
        text=Math.max(0,entitlement-left)+'/'+entitlement+' AI credits';
    }
    const now=new Date(context.now*1000),resetsAt=Date.UTC(now.getUTCFullYear(),now.getUTCMonth()+1,1)/1000;
    return {quotas:[{type:'time',name:'Monthly',percentRemaining:remaining,resetsAt,windowSeconds:2592000,resetText:text}],account:{email:plan}};
}
