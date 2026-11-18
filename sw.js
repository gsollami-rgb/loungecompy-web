// LoungeCompy service worker: notifiche push (il giorno prima del volo)
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('push',e=>{
  let d={};try{d=e.data?e.data.json():{}}catch(x){d={body:e.data&&e.data.text()}}
  const title=d.title||'LoungeCompy';
  e.waitUntil(self.registration.showNotification(title,{body:d.body||'',icon:'/icons/icon-192.png',badge:'/icons/icon-192.png',data:{url:d.url||'/'},tag:d.tag||'lc'}));
});
self.addEventListener('notificationclick',e=>{e.notification.close();const url=(e.notification.data&&e.notification.data.url)||'/';
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(cs=>{for(const c of cs){if('focus' in c){c.navigate(url);return c.focus()}}return self.clients.openWindow(url)}))});
