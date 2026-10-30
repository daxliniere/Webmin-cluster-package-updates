// v0.1.11 review progress JavaScript smoke test - no network access needed.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const js = fs.readFileSync(require('path').join(__dirname,'../cluster-package-updates/review-progress.js'),'utf8');
const elements = {};
function el(id) {
  return elements[id] ||= {
    dataset: {job:'a'.repeat(32)},
    textContent: '',hidden: true,max: 1,value: 0,
    removeAttribute: function (k) { delete this[k]; },
    replaceChildren: function () {this.children=[];},
    appendChild: function(c) {this.children.push(c);}
  };
}
const responses = [
  {status:'reviewing', progress:{phase:'inventory-finished',label:'Test host A',done:1,total:7}, events:[{message:'Inventory completed: Test host A - 12 available updates'}]},
  {status:'preview', progress:{phase:'simulation-finished',done:1,total:1}, events:[]}
];
const queued = [];
let redirected='';
const ctx={
  document:{getElementById:el,createElement:()=>({textContent:''})},
  fetch: async (url,opts) => {assert(url.includes('preview-status.cgi?job=')); assert.strictEqual(opts.credentials,'same-origin');return {ok:true,json:async()=>responses.shift()};},
  window:{setTimeout:cb=>queued.push(cb),location:{replace:url=>{redirected=url;}}},
  console
};
vm.createContext(ctx);
vm.runInContext(js,ctx);
(async()=>{
  await new Promise(r=>setImmediate(r));
  assert(el('cpu-progress-head').textContent.includes('Test host A'),'host progress displayed');
  assert(el('cpu-progress-count').textContent.includes('1 of 7'),'host count shown');
  assert(el('cpu-progress-events').children[0].textContent.includes('12 available updates'),'activity details shown');
  assert.strictEqual(queued.length,1,'next poll queued');
  queued.shift()();
  await new Promise(r=>setImmediate(r));
  assert.strictEqual(redirected, '', 'never redirect outside Authentic Theme navigation');
  assert.strictEqual(el('cpu-review-results-link').hidden, false, 'normal review results link appears');
  assert.strictEqual(el('cpu-review-refresh-link').hidden, true, 'manual refresh link hides after completion');
  assert(el('cpu-progress-head').textContent.includes('complete'), 'completion status shown');
  console.log('PASS: activity displays, completion uses ordinary link, no sidebar-breaking redirect');
})().catch(e=>{console.error(e);process.exit(1)});
