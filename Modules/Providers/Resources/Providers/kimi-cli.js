function read(response, context) {
  var quotas = [], seen = {};
  response.text.split(/\r?\n/).forEach(function(line) {
    var lower = line.toLowerCase(), kind = lower.indexOf('weekly') >= 0 ? 'weekly' : lower.indexOf('monthly') >= 0 ? 'time' : /5h|hour/.test(lower) ? 'session' : null;
    if (!kind || seen[kind]) return;
    var match, percent, reset;
    if (lower.indexOf('% left') >= 0) {
      match = line.match(/(\d+)%\s+left/); if (!match) return; percent = Number(match[1]);
      var m = lower.match(/\(resets\s+in\s+(.+?)\)/); if (m) reset = m[0].replace('(resets in ', '').replace(')', '').trim();
    } else if (lower.indexOf('% used') >= 0) {
      match = line.match(/(\d+)\s*%\s*used/); if (!match) return; percent = Math.max(0, 100-Number(match[1]));
      var m = lower.match(/resets\s+in\s+[0-9dhms ]+/); if (m) reset = m[0].replace(/^resets\s+in\s+/, '').trim();
    } else return;
    var q = {type:kind,percentRemaining:percent,windowSeconds:kind === 'weekly' ? 604800 : kind === 'session' ? 18000 : 2592000};
    if (kind === 'time') q.name = 'Monthly';
    if (reset) { q.resetText = 'Resets in '+reset; var seconds=0; ['d','h','m','s'].forEach(function(unit,i){var m=reset.match(new RegExp('(\\d+)\\s*'+unit));if(m) seconds+=Number(m[1])*[86400,3600,60,1][i];}); if(seconds>0) q.resetsAt=context.now+seconds; }
    quotas.push(q);seen[kind]=true;
  });
  return quotas.length ? {quotas:quotas} : {error:{parseFailed:'No quota data found in Kimi CLI output'}};
}
