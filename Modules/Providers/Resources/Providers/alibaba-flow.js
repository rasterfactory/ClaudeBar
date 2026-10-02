// A pure request planner. All network access belongs to the generic HTTP worker.
function next(responses, context) {
  if(responses.api)return {done:'api'};
  if(responses.console)return {done:'console'};
  var name=context.constants.region||context.settings.region||'intl';
  var region=context.constants.regions[name]||context.constants.regions.intl;
  var credential=context.credential;
  if(credential.mode==='api')return {request:'api',values:{body:JSON.stringify({queryCodingPlanInstanceInfoRequest:{commodityCode:region.commodity}})}};
  function cookie(name) {
    var pairs=credential.token.split(';');
    for(var i=0;i<pairs.length;i++){var pair=pairs[i].replace(/^[^\S\r\n]+|[^\S\r\n]+$/g,''),equals=pair.indexOf('=');if(equals>0 && pair.slice(0,equals)===name && pair.length>equals+1)return pair.slice(equals+1);}
    return null;
  }
  function htmlToken(html) {
    var patterns=[/"sec_token"\s*:\s*"([^"]+)"/,/sec_token\s*=\s*'([^']+)'/,/sec_token\s*=\s*"([^"]+)"/];
    for(var i=0;i<patterns.length;i++){var match=html.match(patterns[i]);if(match)return match[1];}return null;
  }
  var token=cookie('sec_token');
  if(!token){if(!responses.dashboard)return {request:'dashboard'};token=htmlToken(responses.dashboard.text);}
  if(!token)return {error:{sessionExpired:'Re-authenticate in Alibaba Cloud console.'}};
  var params={Api:'zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2',V:'1.0',Data:{queryCodingPlanInstanceInfoRequest:{commodityCode:region.commodity,onlyLatestOne:true}}};
  var values={body:'params='+encodeURIComponent(JSON.stringify(params))+'&region='+encodeURIComponent(region.region)+'&sec_token='+encodeURIComponent(token)};
  var csrf=cookie('login_aliyunid_csrf');if(csrf!=null)values.csrf=csrf;
  return {request:'console',values:values};
}
