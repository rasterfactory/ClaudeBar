// Discover a Code Assist project, then quota. Fixed request templates only.
function next(responses, context) {
  if(responses.quota)return {done:'quota'};
  var p=responses.project,attempts=context.attempts.project||0,max=context.constants.projectAttempts;
  if(!p&&max>0)return {request:'project'};
  var retry=p&&p.status!==200&&p.status!==401&&p.status!==403;
  if(retry&&attempts<max)return {request:'project',delaySeconds:0.2*(attempts+1)};
  var id=p&&p.status===200&&p.json&&p.json.cloudaicompanionProject;
  return {request:'quota',values:{quotaBody:JSON.stringify(typeof id==='string'&&id.length?{project:id}:{})}};
}
