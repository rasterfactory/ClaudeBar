// Vendor facts only. This script does no I/O; the shared worker owns every call.
function object(v){return v!==null&&typeof v==='object'&&!Array.isArray(v);}
function firstString(v,keys){for(var i=0;i<keys.length;i++){var s=v[keys[i]];if(typeof s==='string'&&s.trim().length)return s.trim();}return null;}
function date(value,fractional){if(typeof value!=='string')return null;if(/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:?\d{2})$/.test(value)&& (fractional||!value.match(/\.\d+(?:Z|[+-])/))){var time=Date.parse(value);if(isFinite(time))return time/1000;}if(value.trim()!==''&&isFinite(Number(value)))return Number(value);return null;}
function parseSummary(v){
  if(!object(v))return null;var groups=object(v.response)&&Array.isArray(v.response.groups)?v.response.groups:v.groups;
  if(!Array.isArray(groups))return null;
  var byID=Object.create(null);groups.forEach(function(g){if(!object(g)||!Array.isArray(g.buckets))return;g.buckets.forEach(function(b){if(object(b)&&typeof b.bucketId==='string'&&byID[b.bucketId]===undefined)byID[b.bucketId]=b;});});
  var specs=[['gemini-5h','session',null,'Gemini','5h','Gemini',18000],['gemini-weekly','weekly',null,'Gemini','7d','Gemini Weekly',604800],['3p-5h','model','Claude','Claude & others','5h','Claude',604800],['3p-weekly','model','Claude Weekly','Claude & others','7d','Claude Weekly',604800]];
  var quotas=[];specs.forEach(function(s){var b=byID[s[0]];if(!b||typeof b.remainingFraction!=='number'||!isFinite(b.remainingFraction))return;var q={type:s[1],percentRemaining:b.remainingFraction*100,group:s[3],compactTitle:s[4],menuBarTitle:s[5],windowSeconds:s[6]};if(s[2])q.name=s[2];var reset=date(b.resetTime,true);if(reset!==null)q.resetsAt=reset;quotas.push(q);});return quotas;
}
function modelQuotas(configs){
  if(!Array.isArray(configs))return [];
  var quotas=[];
  for(var i=0;i<configs.length;i++){var c=configs[i];if(!object(c)||typeof c.label!=='string'||!object(c.modelOrAlias)||typeof c.modelOrAlias.model!=='string')throw Error('Invalid model configuration');if(c.quotaInfo==null)continue;if(!object(c.quotaInfo))throw Error('Invalid model quota');var q=c.quotaInfo;if(q.remainingFraction!=null&&typeof q.remainingFraction!=='number')throw Error('Invalid fraction');var row={type:'model',name:c.label,percentRemaining:(q.remainingFraction==null?0:q.remainingFraction)*100,windowSeconds:604800};var reset=date(q.resetTime,false);if(reset!==null)row.resetsAt=reset;quotas.push(row);}
  return quotas;
}
function parseModels(v){
  if(!object(v)||!object(v.models))return [];
  var quotas=[],keys=Object.keys(v.models).sort();
  for(var i=0;i<keys.length;i++){var key=keys[i],m=v.models[key];if(!object(m))return [];if(m.isInternal===true||m.quotaInfo==null)continue;if(!object(m.quotaInfo)||(m.quotaInfo.remainingFraction!=null&&typeof m.quotaInfo.remainingFraction!=='number'))return [];var label=firstString(m,['displayName','label'])||key,q={type:'model',name:label,percentRemaining:(m.quotaInfo.remainingFraction==null?0:m.quotaInfo.remainingFraction)*100,windowSeconds:604800},reset=date(m.quotaInfo.resetTime,false);if(reset!==null)q.resetsAt=reset;quotas.push(q);}
  return quotas;
}
function parsePlan(v){if(!object(v))return null;var paid=object(v.paidTier)?v.paidTier.name:null,current=object(v.currentTier)?v.currentTier.name:null,name=paid!=null?paid:current;return typeof name==='string'&&name.trim()?name.trim():null;}
function read(response,context){
  var envelope=response.json||{},payload=envelope.payload;
  if(envelope.payloadText!==undefined){try{payload=JSON.parse(envelope.payloadText);}catch(e){return {error:{parseFailed:'Invalid JSON: Invalid data'}};}}
  var quotas,format=envelope.format;
  if(format==='summary'){quotas=parseSummary(payload);if(quotas===null)return {error:'noData'};}
  else if(format==='models')quotas=parseModels(payload);
  else if(format==='command'){try{quotas=modelQuotas(payload.clientModelConfigs);}catch(e){return {error:{parseFailed:'Invalid JSON: Invalid model configuration'}};}if(!quotas.length)return {error:{parseFailed:'No valid model quotas found'}};}
  else {
    quotas=parseSummary(payload);
    if(!quotas||!quotas.length){var status=object(payload)&&object(payload.userStatus)?payload.userStatus:{};try{quotas=modelQuotas(status.cascadeModelConfigData&&status.cascadeModelConfigData.clientModelConfigs);}catch(e){return {error:{parseFailed:'Invalid JSON: Invalid model configuration'}};}if(!quotas.length)return {error:{parseFailed:'No valid model quotas found'}};var result={quotas:quotas},info=status.planStatus&&status.planStatus.planInfo;if(typeof status.email==='string')result.account={email:status.email};if(info&&typeof info.planName==='string')result.plan=info.planName.toUpperCase();return result;}
  }
  var result={quotas:quotas},plan=parsePlan(envelope.plan);if(plan)result.plan=plan.toUpperCase();return result;
}
function flag(text,name){var m=text.match(new RegExp(name.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'[=\\s]+([^\\s]+)','i'));return m?m[1]:null;}
function pid(text){var head=text.trim().split(/ +/,1)[0];return /^[+-]?\d+$/.test(head)?Number(head):null;}
function isProcess(text){var lower=text.toLowerCase();if(!['language_server','language_server_macos','language_server_macos_arm','agy'].some(function(n){return lower.indexOf(n)>=0;}))return false;return /(^|\/|\s)agy(\s|$)/.test(lower)||(lower.indexOf('--app_data_dir')>=0&&lower.indexOf('antigravity')>=0)||lower.indexOf('/antigravity/')>=0||lower.indexOf('.antigravity/')>=0;}
function processInfo(text){var lines=text.replace(/\r\n|\r/g,'\n').split('\n');for(var i=0;i<lines.length;i++){var line=lines[i].trim(),id=pid(line);if(!isProcess(line)||id===null)continue;var csrf=flag(line,'--csrf_token');if(!csrf)return {error:'authenticationRequired'};var port=flag(line,'--extension_server_port');return {pid:id,csrf:csrf,extensionPort:port&&/^[+-]?\d+$/.test(port)?Number(port):null};}return null;}
function ports(text){var found=Object.create(null),re=/:(\d+)\s+\(LISTEN\)/g,m;while((m=re.exec(text)))found[m[1]]=true;return Object.keys(found).map(Number).sort(function(a,b){return a-b;});}
function base64Text(text){
  if(text.length%4!==0||!/^[A-Za-z0-9+/]*={0,2}$/.test(text))return null;
  var alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/',acc=0,bits=0,percent='';
  for(var i=0;i<text.length&&text[i]!=='=';i++){acc=(acc<<6)|alphabet.indexOf(text[i]);bits+=6;if(bits>=8){bits-=8;percent+='%'+('0'+((acc>>bits)&255).toString(16)).slice(-2);}}
  try{return decodeURIComponent(percent);}catch(e){return null;}
}
function credentials(text){
  text=text.trim();if(!text)return null;
  if(text.indexOf('go-keyring-base64:')===0){text=base64Text(text.slice('go-keyring-base64:'.length).trim());if(text===null)return null;text=text.trim();}
  var value;try{value=JSON.parse(text);}catch(e){return null;}if(!object(value))return null;
  var source=object(value.token)?value.token:value,access=firstString(source,['access_token','accessToken']),refresh=firstString(source,['refresh_token','refreshToken']),expiry=firstString(source,['expiry','expires_at','expiresAt']);
  if(!access&&!refresh)return null;return {accessToken:access,refreshToken:refresh,expiresAt:expiry===null?null:date(expiry,true)};
}
function usable(c,now){return !!(c&&c.accessToken&&(c.expiresAt===null||c.expiresAt===undefined||c.expiresAt-now>60));}
function next(responses,context){
  var apiOnly=context.constants.apiOnly===true,process=null;
  if(!apiOnly){
    if(!responses.process)return {command:'process'};
    process=processInfo(responses.process.text);
    if(context.availability){if(process&&!process.error)return {result:{available:true}};}
    else if(process&&process.error)return {error:process.error};
    else if(process){
      if(!responses.ports)return {command:'ports',values:{pid:String(process.pid)}};
      var listening=ports(responses.ports.text);if(!listening.length)return {error:{executionFailed:'No listening ports found for Antigravity'}};
      if(responses.local&&responses.local.status===200)return {result:{format:'local',payloadText:responses.local.text}};
      var paths=context.constants.localPaths,n=context.attempts.local||0,secureCount=listening.length*paths.length;
      var port,scheme;if(n<secureCount){port=listening[Math.floor(n/paths.length)];scheme='https';}
      else if(process.extensionPort!==null&&n<secureCount+paths.length){port=process.extensionPort;scheme='http';}
      else return {error:{executionFailed:'Could not connect to Antigravity API'}};
      return {request:'local',values:{scheme:scheme,port:String(port),path:paths[n%paths.length],csrf:process.csrf}};
    }
  }
  var credential;
  if(apiOnly){credential={accessToken:context.credential.token,expiresAt:null};}
  else{if(!responses.keychain)return {command:'keychain'};credential=responses.keychain.exitCode===0?credentials(responses.keychain.text):null;}
  if(context.availability)return {result:{available:credential!==null&&credential.accessToken!==undefined}};
  if(!credential)return {error:{cliNotFound:'Antigravity'}};
  if(!usable(credential,context.now))return {error:{sessionExpired:'Sign in to Antigravity or run `agy` again.'}};
  function callPair(first,second,optional){
    var a=responses[first],b=responses[second];
    if(!a)return {action:{request:first,values:{token:credential.accessToken}}};
    if(optional&&(a.status===401||a.status===403))return {};
    if(!optional&&(a.status===401||a.status===403))return {action:{error:{sessionExpired:'Sign in to Antigravity or run `agy` again.'}}};
    if(a.status>=200&&a.status<300)return {response:a};
    if(!b)return {action:{request:second,values:{token:credential.accessToken}}};
    if(optional&&(b.status===401||b.status===403))return {};
    if(!optional&&(b.status===401||b.status===403))return {action:{error:{sessionExpired:'Sign in to Antigravity or run `agy` again.'}}};
    return b.status>=200&&b.status<300?{response:b}:{};
  }
  var summary=callPair('summaryDaily','summaryStandard',false);if(summary.action)return summary.action;
  var quotas=summary.response&&parseSummary(summary.response.json),format='summary',payload=summary.response&&summary.response.json;
  if(!quotas||!quotas.length){var models=callPair('modelsDaily','modelsStandard',false);if(models.action)return models.action;quotas=models.response&&parseModels(models.response.json);format='models';payload=models.response&&models.response.json;}
  if(!quotas||!quotas.length)return {error:{executionFailed:'Could not reach the Antigravity quota API'}};
  var plan=callPair('planDaily','planStandard',true);if(plan.action)return plan.action;
  return {result:{format:format,payload:payload,plan:plan.response?plan.response.json:null}};
}
