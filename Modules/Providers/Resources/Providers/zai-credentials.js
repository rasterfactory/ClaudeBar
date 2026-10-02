function readCredential(input) {
    const saved=input.credentials.apiKey && input.credentials.apiKey.token;
    const files=input.files||{},names=input.environmentNames||{},env=input.environment||{},constants=input.constants||{};
    const hosts=['api.z.ai','open.bigmodel.cn','dev.bigmodel.cn'];
    const platform=url=>typeof url==='string'?hosts.find(h=>url.includes(h)):null;
    if(constants.platform) {
        return {available:!!saved,credential:saved?{token:saved,baseURL:'https://'+constants.platform}:null};
    }
    let config=null,detected=null;
    if(typeof files.config==='string') {
        try { config=JSON.parse(files.config); } catch(e) {}
        if(config && typeof config==='object' && !Array.isArray(config)) {
            detected=platform(config.env && config.env.ANTHROPIC_BASE_URL);
            if(!detected && Array.isArray(config.providers)) {
                for(const entry of config.providers) {
                    detected=platform(entry && entry.base_url);
                    if(detected)break;
                }
            }
            if(!detected)detected=platform(files.config.toLowerCase());
        }
    }
    const available=!!saved || (input.cli.configured===true && !!detected);
    if(!saved && !input.cli.configured)return {available,error:{cliNotFound:'Claude'}};
    if(!saved && files.config==null)return {available,error:{executionFailed:'Could not read Claude config'}};
    if(!detected && !saved)return {available,error:'authenticationRequired'};
    const valid=value=>typeof value==='string' && value.length>0;
    let token=saved;
    if(!token && config && config.env && valid(config.env.ANTHROPIC_AUTH_TOKEN))token=config.env.ANTHROPIC_AUTH_TOKEN;
    if(!token && config && Array.isArray(config.providers)) {
        for(const entry of config.providers)if(entry && valid(entry.api_key)){token=entry.api_key;break;}
    }
    if(!token && config && valid(config.api_key))token=config.api_key;
    if(!token && valid(env.auth))token=env.auth;
    if(!token)return {available,needEnvironment:names.auth?'auth':null,error:'authenticationRequired'};
    return {available,credential:{token,baseURL:'https://'+(detected||hosts[0])}};
}
