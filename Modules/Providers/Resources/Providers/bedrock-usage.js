// Pricing arithmetic is native in the reusable fetch worker; this maps its report.
function read(response,context){
 var data=response.json;
 if(!data||!Array.isArray(data.lines))return {error:{parseFailed:"Invalid CloudWatch usage response"}};
 return {quotas:data.percentRemaining==null?[]:[{type:"model",name:"Daily Budget",percentRemaining:data.percentRemaining,resetsAt:data.resetsAt,windowSeconds:86400}],tokenSpend:data};
}
