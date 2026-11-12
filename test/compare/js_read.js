document.body.innerText.split('\n').filter(l=>/^(🟢|🔴|🟡|⚪️)/.test(l)).map(l=>l.split('\t')[0]+' | '+(l.split('\t')[2]||'').slice(0,70)).join('\n')
