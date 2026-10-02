// Code Assist model minima, tier aliases and reset text; no I/O.
function read(response, context) {
  var data=response.json;
  if(!data||!Array.isArray(data.buckets)||!data.buckets.length)return {error:{parseFailed:'No quota buckets in response'}};
  var models=Object.create(null);
  data.buckets.forEach(function(b){if(typeof b.modelId!=='string'||typeof b.remainingFraction!=='number')return;
    var old=models[b.modelId];if(!old||b.remainingFraction<old.fraction)models[b.modelId]={model:b.modelId,fraction:b.remainingFraction,reset:b.resetTime||null};});
  function tier(id){id=id.toLowerCase();return id.indexOf('flash-lite')>=0?'Flash Lite':id.indexOf('flash')>=0?'Flash':id.indexOf('pro')>=0?'Pro':null;}
  function version(id){var nums=id.toLowerCase().replace(/gemini-/g,'').split('-')[0].split('.').filter(function(n){return n!==''&&isFinite(Number(n));}).map(Number);return (nums[0]||0)+(nums[1]||0)/100;}
  function preferred(a,b){var ap=/preview/i.test(a),bp=/preview/i.test(b);if(ap!==bp)return !ap;var av=version(a),bv=version(b);return av!==bv?av>bv:a<b;}
  var survivors=Object.create(null);
  Object.keys(models).forEach(function(id){var row=models[id],label=tier(id),key=JSON.stringify([label?'tier:'+label:'model:'+id,row.fraction,row.reset]);row.label=label||id;if(!survivors[key]||preferred(id,survivors[key].model))survivors[key]=row;});
  var rows=Object.keys(survivors).map(function(k){return survivors[k];}).sort(function(a,b){return a.fraction-b.fraction||(a.model<b.model?-1:a.model>b.model?1:0);});
  if(!rows.length)return {error:{parseFailed:'No valid quotas found'}};
  return {quotas:rows.map(function(row){var q={type:'model',name:row.label,percentRemaining:row.fraction*100,windowSeconds:604800};
    if(typeof row.reset==='string'&&/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:?\d{2})$/.test(row.reset)){var reset=Date.parse(row.reset)/1000;if(isFinite(reset)){q.resetsAt=reset;var seconds=reset-context.now;if(seconds>0){var h=Math.floor(seconds/3600),m=Math.floor((seconds%3600)/60);q.resetText=h>0?'Resets in '+h+'h '+m+'m':m>0?'Resets in '+m+'m':'Resets soon';}}}return q;})};
}
