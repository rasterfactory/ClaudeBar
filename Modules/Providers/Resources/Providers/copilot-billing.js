// Billing state changes are returned as data, constrained by writable bindings.
function read(response, context) {
    let json;
    const failure=message=>({error:{parseFailed:'Failed to parse billing response: '+message}});
    try { json=JSON.parse(response.text); } catch(e) { return failure(e.message); }
    const object=v=>v && typeof v==='object' && !Array.isArray(v);
    const number=v=>typeof v==='number' && Number.isFinite(v);
    const integer=v=>number(v) && Number.isInteger(v);
    if(!object(json) || !object(json.timePeriod) || !integer(json.timePeriod.month) || !integer(json.timePeriod.year) || typeof json.user!=='string' || !Array.isArray(json.usageItems))return failure('Invalid billing response');
    const texts=['product','sku','model','unitType'],numbers=['pricePerUnit','grossQuantity','grossAmount','discountQuantity','discountAmount','netQuantity','netAmount'];
    if(json.usageItems.some(item=>!object(item)||texts.some(k=>item[k]!=null && typeof item[k]!=='string')||numbers.some(k=>item[k]!=null && !number(item[k]))))return failure('Invalid usage item');
    const items=json.usageItems.filter(item=>typeof item.product==='string' && item.product.toLowerCase().includes('copilot'));
    const input=context.settings||{},month=json.timePeriod.month,year=json.timePeriod.year;
    const changed=input.lastUsagePeriodMonth!=null && input.lastUsagePeriodYear!=null && (month!==input.lastUsagePeriodMonth || year!==input.lastUsagePeriodYear);
    const effects={lastUsagePeriodMonth:month,lastUsagePeriodYear:year,apiReturnedEmpty:items.length===0};
    if(changed)effects.manualUsageValue=null;
    let limit=Number(input.monthlyLimit==null?50:input.monthlyLimit);
    if(!Number.isFinite(limit) || limit<=0)limit=50;
    const manualValue=changed?null:input.manualUsageValue;
    let used=items.reduce((total,item)=>total+(item.grossQuantity||0),0),manual=false;
    if(input.manualOverrideEnabled===true && manualValue!=null) {
        used=input.manualUsageIsPercent===true?manualValue/100*limit:manualValue;manual=true;
    } else if(input.manualOverrideEnabled===true && !items.length) {
        return {settings:effects,error:{executionFailed:'Manual usage override enabled but no value entered. Please enter your current usage from GitHub settings.'}};
    }
    const now=new Date(context.now*1000),resetsAt=Date.UTC(now.getUTCFullYear(),now.getUTCMonth()+1,1)/1000;
    return {settings:effects,quotas:[{type:'time',name:'Monthly',percentRemaining:(limit-used)/limit*100,resetsAt,windowSeconds:2592000,resetText:Math.trunc(used)+'/'+Math.trunc(limit)+' AI credits'+(manual?' (manual)':'')}],account:{email:context.credential.username||null}};
}
