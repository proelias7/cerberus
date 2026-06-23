const fs = require('fs');
const path = require('path');

const This = GetCurrentResourceName();
const LIB = `server_script "@${This}/src/lib/lib.lua"`;

function getScripts() {
    const scripts = [];
    const numResources = GetNumResources();

    for (let i = 0; i < numResources; i++) {
        const name = GetResourceByFindIndex(i);
        if (name !== This) {
            scripts.push(name);
        }
    }

    return scripts;
}

RegisterCommand('cerberus_install', (source) => {
    if (source !== 0) return;
    
    const scripts = getScripts();
    let count = 0;
    
    for (const script of scripts) {
        const file = LoadResourceFile(script, 'fxmanifest.lua');
        
        if (!file) {
            console.log(`Script ${script} sem fxmanifest`);
        } else if (!file.includes(LIB)) {
            const resourcePath = GetResourcePath(script);
            const filePath = path.join(resourcePath, 'fxmanifest.lua');
            const content = LIB + '\n' + file;
            
            try {
                fs.writeFileSync(filePath, content, 'utf8');
                count++;
                console.log(`Instalado em ${script}`);
            } catch (err) {
                console.log(`Erro em ${script}: ${err.message}`);
            }
        }
    }
    
    console.log(`${count} scripts modificados`);
}, false);

RegisterCommand('cerberus_uninstall', (source) => {
    if (source !== 0) return;
    
    const scripts = getScripts();
    let count = 0;
    
    for (const script of scripts) {
        const file = LoadResourceFile(script, 'fxmanifest.lua');
        
        if (file && file.includes(LIB)) {
            const resourcePath = GetResourcePath(script);
            const filePath = path.join(resourcePath, 'fxmanifest.lua');
            const newContent = file.replace(LIB + '\n', '');
            
            try {
                fs.writeFileSync(filePath, newContent, 'utf8');
                count++;
                console.log(`Removido de ${script}`);
            } catch (err) {
                console.log(`Erro em ${script}: ${err.message}`);
            }
        }
    }
    
    console.log(`${count} scripts modificados`);
}, false);
