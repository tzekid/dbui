(() => {
  'use strict';

  // Fragments stay out of HTTP requests and access logs. Keep the setup secret
  // only in this page's memory and immediately remove it from browser history.
  const setupToken = location.pathname === '/setup' ? location.hash.slice(1) : '';
  if (location.pathname === '/setup' && location.hash) {
    history.replaceState(null, '', location.pathname + location.search);
  }
  const errorBox = document.querySelector('[data-auth-error]');
  const forms = [...document.querySelectorAll('[data-passkey]')];
  const supported = isSecureContext && window.PublicKeyCredential && navigator.credentials;
  let busy = false;

  function showError(message) {
    errorBox.textContent = message;
    errorBox.hidden = false;
  }
  function decode(value) {
    const binary = atob(value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - value.length % 4) % 4));
    return Uint8Array.from(binary, c => c.charCodeAt(0));
  }
  function encode(value) {
    if (value == null) return null;
    let binary = '';
    for (const byte of new Uint8Array(value)) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  async function post(path, body, form) {
    const headers = { 'Content-Type': 'application/json' };
    if (form.dataset.passkey === 'setup') headers['X-dbui-Setup'] = setupToken;
    if (form.dataset.csrf) headers['X-dbui-CSRF'] = form.dataset.csrf;
    const response = await fetch(path, { method: 'POST', credentials: 'same-origin', headers, body: JSON.stringify(body) });
    const result = await response.json();
    if (!response.ok) {
      const error = new Error(result.error || 'The request failed. Try again.');
      error.status = response.status;
      throw error;
    }
    return result;
  }

  for (const form of forms) {
    const button = form.querySelector('button');
    if (!supported) {
      button.disabled = true;
      showError('Passkeys require a current browser and a secure connection. Open dbui in Safari or another browser that supports passkeys.');
    } else if (form.dataset.passkey === 'setup' && !/^[A-Za-z0-9_-]{43}$/.test(setupToken)) {
      button.disabled = true;
      showError('Open the complete setup link provided by the server administrator. If you reloaded this page, open that link again.');
    }
    form.addEventListener('submit', async event => {
      event.preventDefault();
      if (busy || !supported || button.disabled) return;
      const mode = form.dataset.passkey;
      const path = mode === 'add' ? '/auth/passkeys' : `/auth/${mode}`;
      const label = form.elements.label?.value.trim();
      if (label != null && (!label || Array.from(label).length > 64)) {
        showError('Give the passkey a name between 1 and 64 characters.');
        return;
      }
      busy = true;
      for (const other of forms) other.querySelector('button').disabled = true;
      const original = button.textContent;
      button.textContent = mode === 'login' ? 'Waiting for your passkey…' : 'Creating your passkey…';
      form.setAttribute('aria-busy', 'true');
      errorBox.hidden = true;
      try {
        const options = await post(`${path}/options`, {}, form);
        const publicKey = options.publicKey;
        publicKey.challenge = decode(publicKey.challenge);
        if (mode === 'login') {
          if (publicKey.allowCredentials) publicKey.allowCredentials = publicKey.allowCredentials.map(item => ({ ...item, id: decode(item.id) }));
        } else {
          publicKey.user.id = decode(publicKey.user.id);
          publicKey.excludeCredentials = (publicKey.excludeCredentials || []).map(item => ({ ...item, id: decode(item.id) }));
        }
        const credential = mode === 'login'
          ? await navigator.credentials.get({ publicKey })
          : await navigator.credentials.create({ publicKey });
        if (!credential) throw new Error('The passkey request was cancelled. Try again when you are ready.');
        const payload = {
          challenge_id: options.challenge_id,
          credential_id: encode(credential.rawId),
          client_data_json: encode(credential.response.clientDataJSON),
        };
        if (mode === 'login') {
          payload.authenticator_data = encode(credential.response.authenticatorData);
          payload.signature = encode(credential.response.signature);
          payload.user_handle = encode(credential.response.userHandle);
        } else {
          payload.attestation_object = encode(credential.response.attestationObject);
          payload.label = label;
        }
        await post(`${path}/verify`, payload, form);
        location.assign(mode === 'login' ? form.dataset.next || '/' : '/security?added=1');
      } catch (error) {
        let message = error.message;
        if (error.name === 'NotAllowedError' || error.name === 'AbortError') message = 'The passkey request was cancelled or timed out. Try again when you are ready.';
        if (error.name === 'InvalidStateError') message = 'This password manager already has a passkey for dbui. Sign in with it, or choose a different password manager or security key.';
        if (error.name === 'SecurityError') message = 'Open dbui at its own secure address and try again.';
        if (error instanceof TypeError) message = 'Could not reach dbui. Check your connection and try again.';
        showError(message);
        if (error.status === 401 && mode === 'add') {
          const link = document.createElement('a');
          link.href = '/login?next=%2Fsecurity';
          link.textContent = ' Confirm with your passkey';
          errorBox.append(link);
        }
      } finally {
        busy = false;
        button.textContent = original;
        form.removeAttribute('aria-busy');
        for (const other of forms) other.querySelector('button').disabled = false;
      }
    });
  }
  for (const form of document.querySelectorAll('[data-remove-passkey]')) {
    form.addEventListener('submit', event => {
      if (!confirm('Remove this passkey and sign out every session using it?')) event.preventDefault();
    });
  }
})();
