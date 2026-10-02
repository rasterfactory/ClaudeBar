// A harness may report several upstream providers and identities in one response.
function read(response, context) {
    const first=response.text.indexOf('{'), last=response.text.lastIndexOf('}');
    if(first<0 || last<=first) return {error:{parseFailed:'No JSON object in omp usage output'}};
    let payload;
    try {
        payload=jsonDecimal(response.text.slice(first,last+1));
        if(!Array.isArray(payload.reports) || payload.reports.some(r=>typeof r.provider!=='string'||!Array.isArray(r.limits))) throw new Error('Invalid reports');
    } catch(e) { return {error:{parseFailed:'Malformed omp usage JSON: '+e.message}}; }
    const reports=payload.reports, unreported=payload.accountsWithoutUsage||[];
    const counts={}; reports.forEach(r=>counts[r.provider]=(counts[r.provider]||0)+1);
    const quotas=[], metrics=[], labels=new Set(), rows=new Set(), groups=new Set(), menus=new Set();
    const names={'anthropic':'Claude','openai-codex':'Codex','zai':'Z.ai','google-gemini-cli':'Gemini','google-antigravity':'Antigravity','github-copilot':'Copilot','kimi-code':'Kimi','minimax-code':'MiniMax','minimax-code-cn':'MiniMax CN','opencode-go':'OpenCode Go'};
    const name=p=>names[p]||p.split('-').map(s=>s.charAt(0).toUpperCase()+s.slice(1)).join(' ');
    const cap=s=>s.split(/([\s-]+)/).map(t=>t.charAt(0).toUpperCase()+t.slice(1).toLowerCase()).join('');
    const unique=(s,set)=>{let result=s,i=2;while(set.has(result)) result=s+' ('+(i++)+')';set.add(result);return result;};
    const present=v=>typeof v==='string'&&v.length>0;
    const identity=r=>{const m=r.metadata||{};for(const v of [m.email,m.accountId,m.projectId]) if(present(v)) return v;
        for(const l of r.limits) {const s=l.scope||{},v=s.accountId!=null?s.accountId:s.projectId;if(present(v))return v;}return null;};
    const matchId=r=>{if(present((r.metadata||{}).accountId))return r.metadata.accountId;for(const l of r.limits)if(present((l.scope||{}).accountId))return l.scope.accountId;return null;};
    const short=(s,idLimit)=>s.includes('@')?s.split('@')[0].slice(0,16):s.slice(0,idLimit);
    const token=l=>{const s=l.scope||{},w=l.window||{};return s.windowId!=null?s.windowId:(w.id!=null?w.id:(w.label!=null?w.label:'limit'));};
    const money=l=>String((l.amount||{}).unit||'').toLowerCase()==='usd';
    const labelToken=l=>{if(!money(l))return token(l);const s=l.scope||{},w=l.window||{},t=s.windowId!=null?s.windowId:(w.id!=null?w.id:'spend');return t.charAt(0).toUpperCase()+t.slice(1);};
    const meter=l=>{const u=(l.amount||{}).unit;return !money(l)&&present(u)&&u.toLowerCase()!=='percent'?cap(u):null;};
    const strip=(t,p)=>{t=t.trim();return t.toLowerCase().startsWith(p.toLowerCase()+' ')?t.slice(p.length+1).trim():t;};
    const display=(l,p)=>{const s=l.scope||{},w=l.window||{},raw=s.windowId!=null?s.windowId:w.id;
        if(raw!=null&&/^\d{1,4}(s|m|h|d|w|mo|y)$/i.test(raw))return [raw,false];
        const sec=Number(w.durationMs)/1000,total=Math.round(sec);
        if(Number.isFinite(total)&&total>0&&total<9223372036854775808){for(const pair of [[86400,'d'],[3600,'h'],[60,'m']])if(total%pair[0]===0)return [String(total/pair[0])+pair[1],false];return [String(total)+'s',false];}
        if(present(l.label))return [strip(l.label,p),true];if(present(w.label))return [strip(w.label,p),false];return [raw==null?'limit':raw,false];};
    const note=(label,group)=>({label:unique(label,rows),value:'No usage reported',unit:'',icon:'person.crop.circle.badge.questionmark',group:unique(group,groups)});
    reports.forEach((r,index)=>{
        const p=name(r.provider), id=identity(r), discriminator=counts[r.provider]>1?(id?short(id,8):'#'+(index+1)):null;
        const group=discriminator?p+' · '+discriminator:p;
        const before=quotas.length+metrics.length, windows={};
        const key=l=>((l.scope||{}).tier||'')+'|'+token(l);
        r.limits.forEach(l=>windows[key(l)]=(windows[key(l)]||0)+1);
        r.limits.forEach(l=>{
            const a=l.amount||{},w=l.window||{},s=l.scope||{};
            if(money(l)&&a.limit==null&&a.used!=null){const dollars=decimalCents(a.used),t=labelToken(l);
                metrics.push({label:unique(p+' '+t+' Usage'+(discriminator?' · '+discriminator:''),rows),value:t+' usage $'+dollars.replace(/\B(?=(\d{3})+(?!\d))/g,',')+' spent · no cap',unit:'',icon:'dollarsign.circle',group:group});return;}
            if(money(l)&&!(a.limit!=null&&Number(a.limit)>0&&a.used!=null))return;
            let percent;
            if(a.remainingFraction!=null)percent=Number(a.remainingFraction)*100;
            else if(a.usedFraction!=null)percent=(1-Number(a.usedFraction))*100;
            else if(a.used!=null&&Number(a.limit)>0)percent=(Number(a.limit)-Number(a.used))/Number(a.limit)*100;
            else return;
            if(!Number.isFinite(percent))return;
            const m=windows[key(l)]>1?meter(l):null,t=labelToken(l);
            const parts=[p];if(present(s.tier))parts.push(cap(s.tier));if(m)parts.push(m);parts.push(t);if(discriminator)parts.push('· '+discriminator);
            const label=unique(parts.join(' '),labels);
            const title=[];if(present(s.tier))title.push(cap(s.tier));
            if(money(l)){if(m)title.push(m);title.push(t);}else{const d=display(l,p);if(m&&!d[1])title.push(m);title.push(d[0]);}
            const quota={type:'time',name:label,percentRemaining:percent,group:group,compactTitle:title.join(' '),resetsAt:w.resetsAt!=null?Number(w.resetsAt)/1000:null,windowSeconds:Number(w.durationMs)>0?Number(w.durationMs)/1000:null};
            if(discriminator&&discriminator.length>8)quota.menuBarTitle=unique(label.replace('· '+discriminator,'· '+discriminator.slice(0,7)+'…'),menus);
            if(money(l))quota.spend={used:decimalCents(a.used),limit:decimalCents(a.limit)};
            quotas.push(quota);
        });
        if(before<quotas.length+metrics.length)groups.add(group);else{const full=id||discriminator||'account '+(index+1);metrics.push(note(p+' · '+full,p+' · '+short(full,16)));}
    });
    const email=s=>typeof s==='string'&&s.trim()?s.trim().toLowerCase():null;
    const matches=(a,p,e,id)=>{if(a.provider!==p||present(a.orgId))return false;const ae=email(a.email),be=email(e);if(ae&&be)return ae===be;return present(a.accountId)&&present(id)&&a.accountId===id;};
    const emitted=[];
    unreported.forEach(a=>{
        if(reports.some(r=>matches(a,r.provider,(r.metadata||{}).email,matchId(r)))||emitted.some(e=>!present(e.orgId)&&matches(a,e.provider,e.email,e.accountId)))return;
        emitted.push(a);const p=name(a.provider),id=a.type==='api_key'?'API key':([a.email,a.accountId,a.projectId,a.enterpriseUrl].find(present)||'OAuth account');
        metrics.push(note(p+' · '+id,p+' · '+short(id,16)));
    });
    if(!quotas.length&&!metrics.length)return {error:'noData'};
    const emails=new Set(reports.map(r=>(r.metadata||{}).email).concat(unreported.map(a=>a.email)).filter(e=>e!=null));
    return {quotas:quotas,metrics:metrics.length?metrics:null,account:{email:emails.size===1?Array.from(emails)[0]:null}};
}
