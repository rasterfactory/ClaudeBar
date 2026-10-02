// Kiro's plain /usage output, with dates interpreted in the host's local zone.
function read(response, context) {
    const text = response.text.replace(/\u001B\[[0-9;]*[a-zA-Z]/g, "");
    const now = new Date(context.now*1000);
    const quotas = [];
    const bonus = text.match(/Bonus credits:\s*([\d.]+)\/([\d.]+)/);
    if (bonus && Number(bonus[2]) > 0) {
        const expiry = text.match(/expires in (\d+) days/);
        const days = expiry ? Number(expiry[1]) : null;
        quotas.push({type:"weekly", percentRemaining:Math.max(0,(Number(bonus[2])-Number(bonus[1]))/Number(bonus[2])*100),
            resetsAt:days === null ? null : context.now+days*86400,
            resetText:days === null ? null : "Expires in "+days+" days", windowSeconds:604800});
    }
    const credits = text.match(/Credits \(([\d.]+) of ([\d.]+)/);
    if (credits && Number(credits[2]) > 0) {
        const reset = text.match(/resets on (\d{2})\/(\d{2})/);
        let date = null;
        if (reset) {
            date = new Date(now.getFullYear(),Number(reset[1])-1,Number(reset[2]));
            if (date < now) date = new Date(now.getFullYear()+1,Number(reset[1])-1,Number(reset[2]));
        }
        quotas.push({type:"time",name:"Monthly", percentRemaining:Math.max(0,(Number(credits[2])-Number(credits[1]))/Number(credits[2])*100),
            resetsAt:date ? date.getTime()/1000 : null, resetText:reset ? "Resets on "+reset[1]+"/"+reset[2] : null, windowSeconds:2592000});
    }
    return quotas.length ? {quotas:quotas} : {error:{parseFailed:"No quota data found in Kiro CLI output"}};
}
