// Pure parser for Gemini CLI /stats; no I/O.
function read(response, context) {
  var text=response.text.replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g,'');
  if(/login with google|use gemini api key|waiting for auth/i.test(text))return {error:'authenticationRequired'};
  var quotas=[];
  text.split(/\r\n|\r|\n/).forEach(function(line){
    var m=line.replace(/│/g,' ').match(/(gemini[-\w.]+)\s+.*?([0-9]+(?:\.[0-9]+)?)\s*%\s*\(([^)]+)\)/i);
    if(m)quotas.push({type:'model',name:m[1],percentRemaining:Number(m[2]),resetText:m[3].trim()});
  });
  return quotas.length?{quotas:quotas}:{error:{parseFailed:'No usage data found in output'}};
}
