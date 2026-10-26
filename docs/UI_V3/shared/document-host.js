'use strict';
// Same-origin HTML prototype host. Native implementation uses native module scopes.
// A zero-script iframe reproduces IAB's injected observer/non-Node error; object
// documents avoid that failing bootstrap path while retaining HTML and postMessage.
// Local files have opaque origins: iframe WindowProxy remains addressable without
// reading a cross-origin contentDocument, so the host can verify message sources.
window.V3DocumentHost=(()=>{function bind(node){if(!node||node.tagName!=='OBJECT')throw new TypeError('Document host must be an object element');if(node.dataset.documentHost==='true')return node;node.type='text/html';node.dataset.documentHost='true';Object.defineProperties(node,{src:{get(){return this.data},set(value){this.data=String(value)}},contentWindow:{get(){return this.contentDocument?.defaultView||null}}});return node}function create(){if(location.protocol==='file:'){const frame=document.createElement('iframe');frame.dataset.documentHost='true';return frame}return bind(document.createElement('object'))}return Object.freeze({create,bind});})();
