// Pure mapping of Vibe's existing meta.json costs and token totals; no repricing or I/O.
function read(response,context){
  var data=response.json||{},today={date:data.todayStart,totalCost:'0',totalTokens:0,workingTime:0,sessionCount:0},previous={date:data.yesterdayStart,totalCost:'0',totalTokens:0,workingTime:0,sessionCount:0};
  (data.entries||[]).forEach(function(entry){
    var parts=entry.name.split('_');if(parts.length<3||parts[0]!=='session'||!/^\d{8}$/.test(parts[1])||!/^\d{6}$/.test(parts[2]))return;
    var d=parts[1],t=parts[2],instant=Date.UTC(Number(d.slice(0,4)),Number(d.slice(4,6))-1,Number(d.slice(6,8)),Number(t.slice(0,2)),Number(t.slice(2,4)),Number(t.slice(4,6)))/1000;
    var parsed=new Date(instant*1000);if(!isFinite(instant)||parsed.getUTCFullYear()!==Number(d.slice(0,4))||parsed.getUTCMonth()+1!==Number(d.slice(4,6))||parsed.getUTCDate()!==Number(d.slice(6,8))||parsed.getUTCHours()!==Number(t.slice(0,2))||parsed.getUTCMinutes()!==Number(t.slice(2,4))||parsed.getUTCSeconds()!==Number(t.slice(4,6)))return;
    var stat=instant>=data.todayStart&&instant<data.todayEnd?today:instant>=data.yesterdayStart&&instant<data.todayStart?previous:null;if(!stat)return;
    var raw,exact;try{raw=JSON.parse(entry.text);exact=jsonDecimal(entry.text);}catch(e){return;}
    if(!raw||!raw.stats||!exact||!exact.stats)return;
    var tokens=raw.stats.session_total_llm_tokens!=null?raw.stats.session_total_llm_tokens:raw.stats.sessionTotalLlmTokens;
    var cost=raw.stats.session_cost!=null?raw.stats.session_cost:raw.stats.sessionCost;
    var decimal=exact.stats.session_cost!=null?exact.stats.session_cost:exact.stats.sessionCost;
    if(typeof tokens!=='number'||!Number.isInteger(tokens)||typeof cost!=='number'||!isFinite(cost)||typeof decimal!=='string')return;
    var sum=decimalAdd(stat.totalCost,decimal);if(sum===null)return;
    stat.totalCost=sum;stat.totalTokens+=tokens;stat.sessionCount++;
  });
  return {quotas:[],dailyUsageReport:{today:today,previous:previous}};
}
