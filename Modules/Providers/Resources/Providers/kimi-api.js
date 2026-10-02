function read(response, context) {
  function object(x) { return x && typeof x === 'object' && !Array.isArray(x); }
  function detail(x) { return object(x) && typeof x.limit === 'string' && typeof x.resetTime === 'string' && (x.used == null || typeof x.used === 'string') && (x.remaining == null || typeof x.remaining === 'string'); }
  var data=response.json;
  if (!object(data) || !Array.isArray(data.usages) || !data.usages.every(function(u){return object(u) && typeof u.scope==='string' && detail(u.detail) && (u.limits==null || Array.isArray(u.limits) && u.limits.every(function(l){return object(l) && object(l.window) && Number.isInteger(l.window.duration) && typeof l.window.timeUnit==='string' && detail(l.detail);}));})) return {error:{parseFailed:'Failed to decode Kimi response: invalid response shape'}};
  var coding=data.usages.filter(function(u){return u.scope==='FEATURE_CODING';})[0];
  if(!coding) return {error:{parseFailed:'Missing FEATURE_CODING scope in response'}};
  function integer(s) { return typeof s==='string' && /^[+-]?\d+$/.test(s) && Number.isSafeInteger(Number(s)) ? Number(s) : null; }
  function quota(d,type) { var limit=integer(d.limit)||0,used=integer(d.used),remaining=integer(d.remaining); if(used==null && remaining==null){used=0;remaining=Math.max(0,limit);} else if(used==null) used=Math.max(0,limit-remaining);else if(remaining==null) remaining=Math.max(0,limit-used);var q={type:type,percentRemaining:limit>0 ? remaining/limit*100 : 100,windowSeconds:type==='weekly'?604800:18000,resetText:used+'/'+limit+' requests'+(type==='session'?' (5h)':'')};var date=Date.parse(d.resetTime);if(isFinite(date))q.resetsAt=date/1000;return q; }
  var quotas=[quota(coding.detail,'weekly')], limits=coding.limits||[],rate=limits.filter(function(l){return l.window.duration===300&&l.window.timeUnit==='TIME_UNIT_MINUTE';})[0]||limits[0];if(rate)quotas.push(quota(rate.detail,'session'));
  var result={quotas:quotas},tier={1024:'Andante',2048:'Moderato',7168:'Allegretto'}[integer(coding.detail.limit)];if(tier)result.plan=tier;return result;
}
