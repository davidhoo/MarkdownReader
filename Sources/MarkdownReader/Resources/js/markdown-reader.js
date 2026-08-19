(function() {
  const MR = {
    version: '2.0.0',

    scrollToHeading(id) {
      const el = document.getElementById(id);
      if (el) {
        el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        el.classList.add('outline-highlight');
        setTimeout(() => {
          el.classList.add('fade-out');
          setTimeout(() => {
            el.classList.remove('outline-highlight', 'fade-out');
          }, 300);
        }, 1500);
      }
    },

    scrollToLine(lineNumber) {
      const target = document.querySelector(`[data-line="${lineNumber}"]`);
      if (target) {
        target.scrollIntoView({ behavior: 'smooth', block: 'center' });
        return true;
      }
      let closest = null;
      let minDiff = Infinity;
      document.querySelectorAll('[data-line]').forEach(el => {
        const diff = Math.abs(parseInt(el.dataset.line) - lineNumber);
        if (diff < minDiff) {
          minDiff = diff;
          closest = el;
        }
      });
      if (closest) {
        closest.scrollIntoView({ behavior: 'smooth', block: 'center' });
        return true;
      }
      return false;
    },

    replaceContent(html) {
      const content = document.getElementById('mr-content');
      if (!content) return false;

      content.innerHTML = html;
      MR._searchHighlights = [];
      MR.renderMermaid();
      MR.renderPlantUML();
      MR.renderKaTeX();
      MR.renderAdmonitions();
      MR.addCopyButtons();
      if (typeof Prism !== 'undefined') {
        Prism.highlightAll();
      }
      return true;
    },

    getVisibleHeading() {
      const headings = document.querySelectorAll('h1[id], h2[id], h3[id], h4[id], h5[id], h6[id]');
      let visible = null;
      const scrollTop = window.scrollY || document.documentElement.scrollTop;
      const threshold = 100;
      for (let i = headings.length - 1; i >= 0; i--) {
        if (headings[i].getBoundingClientRect().top <= threshold) {
          visible = {
            id: headings[i].id,
            level: parseInt(headings[i].tagName.charAt(1)),
            title: headings[i].textContent.trim(),
            lineNumber: parseInt(headings[i].dataset.line || '0')
          };
          break;
        }
      }
      return visible;
    },

    getTopVisibleLine() {
      const elements = document.querySelectorAll('[data-line]');
      const threshold = 120;
      let best = null;
      let minDiff = Infinity;
      for (let i = elements.length - 1; i >= 0; i--) {
        const rect = elements[i].getBoundingClientRect();
        const diff = threshold - rect.top;
        if (diff >= 0 && diff < minDiff) {
          minDiff = diff;
          best = elements[i];
        }
      }
      if (best) {
        return parseInt(best.dataset.line) || 1;
      }
      return 1;
    },

    getScrollPosition() {
      return {
        x: window.scrollX || document.documentElement.scrollLeft,
        y: window.scrollY || document.documentElement.scrollTop
      };
    },

    _resolveThemeColors() {
      const scriptTag = document.querySelector('script[src*="markdown-reader.js"]');
      const isDark = scriptTag ? scriptTag.dataset.isDark === 'true' : true;

      // Mermaid strips var() refs (sanitizeDirective) and khroma needs hex for adjust/darken/invert.
      const style = getComputedStyle(document.documentElement);
      const resolve = (v) => {
        if (!v || !v.startsWith('var(')) return v;
        const inner = v.slice(4, v.lastIndexOf(')')).trim();
        const name = inner.includes(',') ? inner.slice(0, inner.indexOf(',')).trim() : inner;
        let resolved = style.getPropertyValue(name).trim();
        if (resolved.startsWith('var(')) resolved = resolve(resolved);
        return resolved || v;
      };

      // Canvas fillStyle converts CSS colors to #rrggbb but drops the alpha channel.
      // For rgba() values (common in theme borders/muted text), blend with the
      // surface background first so the result matches what users see on screen.
      const toHex = (cssColor) => {
        if (!cssColor || cssColor.startsWith('#')) return cssColor;
        const ctx = document.createElement('canvas').getContext('2d');
        ctx.fillStyle = cssColor;
        const result = ctx.fillStyle;
        // If rgba was converted to #rrggbb, alpha was lost — pre-blend it
        if (result.startsWith('#') && cssColor.includes('rgba')) {
          const match = cssColor.match(/rgba?\(\s*(\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)/);
          if (match) {
            const r = parseInt(match[1]), g = parseInt(match[2]), b = parseInt(match[3]), a = parseFloat(match[4]);
            const surface = isDark ? [24, 24, 26] : [255, 255, 255];
            const blended = [
              Math.round(surface[0] * (1 - a) + r * a),
              Math.round(surface[1] * (1 - a) + g * a),
              Math.round(surface[2] * (1 - a) + b * a)
            ];
            return '#' + blended.map(c => c.toString(16).padStart(2, '0')).join('');
          }
        }
        return result;
      };

      return {
        isDark,
        themeVariables: {
          primaryColor: toHex(resolve('var(--accent)')),
          primaryTextColor: toHex(resolve('var(--ink)')),
          primaryBorderColor: toHex(resolve('var(--border)')),
          lineColor: toHex(resolve('var(--fg-muted)')),
          secondaryColor: toHex(resolve('var(--bg-elevated)')),
          tertiaryColor: toHex(resolve('var(--bg-subtle)'))
        }
      };
    },

    _showMermaidError(container, msg) {
      container.innerHTML = '';
      const errBox = document.createElement('div');
      errBox.className = 'mermaid-error';
      errBox.innerHTML = '<strong>Mermaid</strong> — ' + msg;
      container.appendChild(errBox);
    },

    async _encodePlantUML(text) {
      // Kroki 要求 base64url(zlib deflate, 含 zlib header)。
      // 注意：plantuml.com 公共服务器（1.2026.7beta6）当前对所有 ~1
      // deflate-raw 编码请求都错误返回 “This URL does not look like
      // HUFFMAN data”，故改用 Kroki 作为渲染服务器。
      const encoder = new TextEncoder();
      const data = encoder.encode(text);

      // CompressionStream('deflate') 产出含 zlib header 的 deflate 流，
      // 与 Node zlib.deflateSync 一致，正是 Kroki 期望的格式。
      const cs = new CompressionStream('deflate');
      const writer = cs.writable.getWriter();
      writer.write(data);
      writer.close();

      const reader = cs.readable.getReader();
      const chunks = [];
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
      }
      const compressed = new Uint8Array(chunks.reduce((acc, c) => acc + c.length, 0));
      let offset = 0;
      for (const chunk of chunks) {
        compressed.set(chunk, offset);
        offset += chunk.length;
      }

      // base64url 编码（URL 安全，无填充）
      let binary = '';
      for (let i = 0; i < compressed.length; i++) {
        binary += String.fromCharCode(compressed[i]);
      }
      const b64 = btoa(binary);
      return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    },

    _showPlantUMLError(container, msg) {
      container.innerHTML = '';
      const errBox = document.createElement('div');
      errBox.className = 'plantuml-error';
      errBox.innerHTML = '<strong>PlantUML</strong> — ' + msg;
      container.appendChild(errBox);
    },

    renderMermaid() {
      const mermaidBlocks = document.querySelectorAll('code.language-mermaid, pre code.language-mermaid');
      if (mermaidBlocks.length === 0) return;
      if (typeof mermaid === 'undefined') return;

      const { isDark, themeVariables } = MR._resolveThemeColors();

      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'loose',
        theme: isDark ? 'dark' : 'default',
        themeVariables
      });

      let idx = 0;
      mermaidBlocks.forEach(block => {
        const pre = block.parentElement;
        if (!pre || pre.tagName !== 'PRE') return;
        const source = block.textContent;
        const container = document.createElement('div');
        container.className = 'mermaid-container';
        container.dataset.mermaidSource = source;
        const id = 'mermaid-' + (++idx) + '-' + Math.random().toString(36).slice(2);
        mermaid.render(id, source).then(({ svg, bindFunctions }) => {
          container.innerHTML = svg;
          if (bindFunctions) bindFunctions(container);
        }).catch(err => {
          console.error('[MarkdownReader] mermaid.render error:', err);
          const detail = (err && err.message) ? String(err.message).substring(0, 200) : String(err).substring(0, 200);
          MR._showMermaidError(container, '渲染失败：' + detail);
        });
        pre.replaceWith(container);
      });
    },

    rerenderMermaid() {
      const containers = document.querySelectorAll('.mermaid-container');
      if (containers.length === 0) return;
      if (typeof mermaid === 'undefined') return;

      const { isDark, themeVariables } = MR._resolveThemeColors();

      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'loose',
        theme: isDark ? 'dark' : 'default',
        themeVariables
      });

      containers.forEach((container, idx) => {
        const source = container.dataset.mermaidSource;
        if (!source) return;
        const id = 'mermaid-re-' + idx + '-' + Math.random().toString(36).slice(2);
        container.innerHTML = '';
        mermaid.render(id, source).then(({ svg, bindFunctions }) => {
          container.innerHTML = svg;
          if (bindFunctions) bindFunctions(container);
        }).catch(err => {
          console.error('[MarkdownReader] mermaid rerender error:', err);
          const detail = (err && err.message) ? String(err.message).substring(0, 200) : String(err).substring(0, 200);
          MR._showMermaidError(container, '渲染失败：' + detail);
        });
      });
    },

    async _fetchPlantUMLSVG(source, serverUrl) {
      const encoded = await MR._encodePlantUML(source);
      // Kroki: /plantuml/svg/<base64url(zlib deflate)>
      const svgUrl = `${serverUrl}/plantuml/svg/${encoded}`;
      const response = await fetch(svgUrl);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const text = await response.text();
      if (!text.trim().startsWith('<svg')) {
        throw new Error('服务器返回了无效的 SVG 内容');
      }
      return text;
    },

    _applyPlantUMLSVG(container, svgText) {
      container.innerHTML = svgText;
      const svgEl = container.querySelector('svg');
      if (svgEl) {
        svgEl.removeAttribute('width');
        svgEl.removeAttribute('height');
        svgEl.style.maxWidth = '100%';
        svgEl.style.height = 'auto';
      }
    },

    async renderPlantUML() {
      const plantumlBlocks = document.querySelectorAll('code.language-plantuml, pre code.language-plantuml, code.language-puml, pre code.language-puml');
      if (plantumlBlocks.length === 0) return;

      const serverUrl = 'https://kroki.io';

      const tasks = Array.from(plantumlBlocks).map(block => {
        const pre = block.parentElement;
        if (!pre || pre.tagName !== 'PRE') return Promise.resolve();

        const source = block.textContent;
        const container = document.createElement('div');
        container.className = 'plantuml-container';
        container.dataset.plantumlSource = source;

        container.innerHTML = '<div class="plantuml-loading">PlantUML...</div>';
        pre.replaceWith(container);

        return MR._fetchPlantUMLSVG(source, serverUrl)
          .then(svg => { MR._applyPlantUMLSVG(container, svg); })
          .catch(err => {
            console.error('[MarkdownReader] PlantUML render error:', err);
            MR._showPlantUMLError(container, '渲染失败：' + (err.message || String(err)).substring(0, 200));
          });
      });

      await Promise.all(tasks);
    },

    async rerenderPlantUML() {
      const containers = document.querySelectorAll('.plantuml-container');
      if (containers.length === 0) return;

      const serverUrl = 'https://kroki.io';

      const tasks = Array.from(containers).map(container => {
        const source = container.dataset.plantumlSource;
        if (!source) return Promise.resolve();
        container.innerHTML = '<div class="plantuml-loading">PlantUML...</div>';

        return MR._fetchPlantUMLSVG(source, serverUrl)
          .then(svg => { MR._applyPlantUMLSVG(container, svg); })
          .catch(err => {
            console.error('[MarkdownReader] PlantUML rerender error:', err);
            MR._showPlantUMLError(container, '渲染失败：' + (err.message || String(err)).substring(0, 200));
          });
      });

      await Promise.all(tasks);
    },

    renderKaTeX() {
      const mathElements = document.querySelectorAll('code.language-math, code.language-latex, code.language-katex');
      if (mathElements.length === 0) return;
      if (typeof katex === 'undefined') return;

    mathElements.forEach(block => {
      const pre = block.parentElement;
      const isInline = !pre || pre.tagName !== 'PRE';
      const mathContent = block.textContent;

      if (isInline) {
        const span = document.createElement('span');
          const isDisplayMode = block.dataset.display === 'true';
          span.className = 'katex-inline';
          try {
            katex.render(mathContent, span, {
              displayMode: isDisplayMode,
              throwOnError: false,
              output: 'html'
            });
          } catch (e) {
            span.textContent = mathContent;
          }
          block.replaceWith(span);
        } else {
          const container = document.createElement('div');
          container.className = 'katex-display';
          try {
            katex.render(mathContent, container, {
              displayMode: true,
              throwOnError: false,
              output: 'html'
            });
          } catch (e) {
            container.textContent = mathContent;
          }
          pre.replaceWith(container);
        }
      });
    },

    renderAdmonitions() {
      const blockquotes = document.querySelectorAll('blockquote');
      const types = {
        'note': { icon: 'ℹ', label: 'Note' },
        'tip': { icon: '💡', label: 'Tip' },
        'warning': { icon: '⚠', label: 'Warning' },
        'caution': { icon: '🔥', label: 'Caution' },
        'important': { icon: '❗', label: 'Important' }
      };
      blockquotes.forEach(bq => {
        const firstP = bq.querySelector('p');
        if (!firstP) return;
        const text = firstP.textContent.trim();
        for (const [type, config] of Object.entries(types)) {
          const prefix = '[' + type.charAt(0).toUpperCase() + type.slice(1) + ']';
          if (text.startsWith(prefix)) {
            bq.classList.add('admonition', 'admonition-' + type);
            const titleSpan = document.createElement('span');
            titleSpan.className = 'admonition-title';
            titleSpan.textContent = config.label;
            const rest = text.slice(prefix.length).trim();
            if (rest) {
              firstP.textContent = rest;
            } else {
              firstP.remove();
            }
            bq.insertBefore(titleSpan, bq.firstChild);
            break;
          }
        }
      });
    },

    addCopyButtons() {
      const preBlocks = document.querySelectorAll('pre');
      preBlocks.forEach(pre => {
        if (pre.querySelector('.mr-copy-btn')) return;
        pre.style.position = 'relative';

        const btn = document.createElement('button');
        btn.className = 'mr-copy-btn';
        btn.type = 'button';
        btn.title = 'Copy';
        btn.innerHTML = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="9" height="9" rx="1.5"/><path d="M3 11V3a1.5 1.5 0 0 1 1.5-1.5H11"/></svg>';

        btn.addEventListener('click', function() {
          const code = pre.querySelector('code');
          const text = code ? code.textContent : pre.textContent;
          navigator.clipboard.writeText(text).then(() => {
            btn.classList.add('mr-copy-btn-copied');
            btn.innerHTML = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="3.5 8.5 6.5 11.5 12.5 5.5"/></svg>';
            setTimeout(() => {
              btn.classList.remove('mr-copy-btn-copied');
              btn.innerHTML = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="9" height="9" rx="1.5"/><path d="M3 11V3a1.5 1.5 0 0 1 1.5-1.5H11"/></svg>';
            }, 2000);
          }).catch(() => {
            const textarea = document.createElement('textarea');
            textarea.value = text;
            textarea.style.position = 'fixed';
            textarea.style.opacity = '0';
            document.body.appendChild(textarea);
            textarea.select();
            document.execCommand('copy');
            document.body.removeChild(textarea);
            btn.classList.add('mr-copy-btn-copied');
            btn.innerHTML = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="3.5 8.5 6.5 11.5 12.5 5.5"/></svg>';
            setTimeout(() => {
              btn.classList.remove('mr-copy-btn-copied');
              btn.innerHTML = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="9" height="9" rx="1.5"/><path d="M3 11V3a1.5 1.5 0 0 1 1.5-1.5H11"/></svg>';
            }, 2000);
          });
        });

        pre.appendChild(btn);
      });
    },

    _searchHighlights: [],

    // 内容区复制按钮相关状态
    _documentCopyTimer: null,

    /// 复制渲染态富文本：临时选中 #mr-content 后走浏览器原生 copy 路径，
    /// 确保剪贴板效果等同页面内全选复制。finally 中无论成败都恢复原选区。
    /// 不得使用 navigator.clipboard.writeText 或隐藏 textarea（只复制纯文本）。
    copyRenderedContent() {
      const content = document.getElementById('mr-content');
      if (!content) return false;
      const selection = window.getSelection();
      const oldRanges = Array.from({ length: selection.rangeCount }, (_, index) => selection.getRangeAt(index).cloneRange());
      const range = document.createRange();
      try {
        range.selectNodeContents(content);
        selection.removeAllRanges();
        selection.addRange(range);
        return document.execCommand('copy');
      } finally {
        selection.removeAllRanges();
        oldRanges.forEach(oldRange => selection.addRange(oldRange));
      }
    },

    /// 文档复制按钮的 mask 图标是否可用：要求 :root 同时存在两个 CSS 变量。
    /// unavailable 时不创建按钮，setDocumentCopyButtonHidden / setDocumentCopyButtonLabels
    /// 与复制命令必须安全处理按钮不存在。
    _documentCopyIconsAvailable() {
      const rootStyle = getComputedStyle(document.documentElement);
      const copyIcon = rootStyle.getPropertyValue('--mr-document-copy-icon').trim();
      const copiedIcon = rootStyle.getPropertyValue('--mr-document-copied-icon').trim();
      return Boolean(copyIcon) && Boolean(copiedIcon);
    },

    /// 设置按钮的 mask glyph 子节点。isCopied=true 切到成功态 class。
    /// 只替换 glyph 子节点，不触碰 button type/id/title/aria-label/颜色 class/计时器/listener。
    setDocumentCopyButtonIcon(button, isCopied) {
      let glyph = button.querySelector('.mr-document-copy-glyph');
      if (!glyph) {
        glyph = document.createElement('span');
        glyph.setAttribute('aria-hidden', 'true');
        button.appendChild(glyph);
      }
      glyph.className = isCopied
        ? 'mr-document-copy-glyph mr-document-copy-glyph-copied'
        : 'mr-document-copy-glyph';
    },

    /// 幂等创建内容区复制按钮。元素追加到 #mr-content 外部（document.body），
    /// position: fixed 固定于内容视口右上角，不随正文滚动、不被复制进正文。
    /// 不得随 MR.replaceContent() 删除。两个 mask 图标变量不可用时跳过创建。
    /// 仅当 .markdown-preview 的 data-document-copy-enabled 为 "true" 时才创建，
    /// 以保护未启用入口（PDF/打印、总开关关闭）。
    addDocumentCopyButton() {
      if (document.getElementById('mr-document-copy-btn')) {
        MR.setDocumentCopyButtonLabels();
        return;
      }
      const preview = document.querySelector('.markdown-preview');
      if (preview && preview.dataset.documentCopyEnabled !== 'true') return;
      if (!MR._documentCopyIconsAvailable()) return;

      const normalTitle = (preview && preview.dataset.documentCopyTitle) || 'Copy Content';
      const btn = document.createElement('button');
      btn.id = 'mr-document-copy-btn';
      btn.className = 'mr-document-copy-btn';
      btn.type = 'button';
      btn.title = normalTitle;
      btn.setAttribute('aria-label', normalTitle);
      MR.setDocumentCopyButtonIcon(btn, false);
      btn.dataset.normalTitle = normalTitle;
      btn.dataset.copiedTitle = (preview && preview.dataset.documentCopiedTitle) || 'Content Copied';

      btn.addEventListener('click', function() {
        // 按格式选择复制路径：rawMarkdown 用临时 textarea 复制文件原文，
        // 其余（含主阅读富文本）走 copyRenderedContent 的 selection 路径。
        // 任一路径返回失败都不显示成功反馈。
        const format = (preview && preview.dataset.documentCopyFormat) || 'richText';
        const ok = format === 'rawMarkdown'
          ? MR.copyRawMarkdownContent(preview && preview.dataset.documentCopyRawBase64)
          : MR.copyRenderedContent();
        if (!ok) return;
        // 连续点击：clearTimeout 后重新计时，旧计时不会提前恢复复制图标。
        if (MR._documentCopyTimer) {
          clearTimeout(MR._documentCopyTimer);
          MR._documentCopyTimer = null;
        }
        btn.classList.add('mr-document-copy-btn-copied');
        MR.setDocumentCopyButtonIcon(btn, true);
        btn.title = btn.dataset.copiedTitle;
        btn.setAttribute('aria-label', btn.dataset.copiedTitle);
        MR._documentCopyTimer = setTimeout(() => {
          MR._documentCopyTimer = null;
          btn.classList.remove('mr-document-copy-btn-copied');
          MR.setDocumentCopyButtonIcon(btn, false);
          btn.title = btn.dataset.normalTitle;
          btn.setAttribute('aria-label', btn.dataset.normalTitle);
        }, 5000);
      });

      document.body.appendChild(btn);
    },

    /// 总开关变化：无重载地增删按钮。
    /// 关闭：clear timer + remove 按钮，无成功态/定时器/hit target 残留。
    /// 开启：幂等创建（addDocumentCopyButton 自身保证只创建一个）。按钮不存在时安全 no-op。
    setDocumentCopyButtonEnabled(enabled) {
      const btn = document.getElementById('mr-document-copy-btn');
      if (!enabled) {
        if (MR._documentCopyTimer) {
          clearTimeout(MR._documentCopyTimer);
          MR._documentCopyTimer = null;
        }
        if (btn) btn.remove();
        return;
      }
      MR.addDocumentCopyButton();
    },

    /// 将 base64 编码的 UTF-8 原始 Markdown 解码为字符串。
    /// 用 atob 取字节，再以 TextDecoder('utf-8') 解码，保证中文/emoji 字节保真。
    decodeUTF8Base64(base64) {
      const bytes = Uint8Array.from(atob(base64), function (ch) { return ch.charCodeAt(0); });
      return new TextDecoder('utf-8').decode(bytes);
    },

    /// 复制原始 Markdown 文本：通过临时 textarea + document.execCommand('copy')
    /// 写入纯文本。payload 缺失或 decode/复制失败返回 false，不显示成功反馈。
    /// 仅用于 rawMarkdown 格式；不得替换富文本的 selection 复制路径。
    copyRawMarkdownContent(base64) {
      if (!base64) return false;
      const textarea = document.createElement('textarea');
      try {
        textarea.value = MR.decodeUTF8Base64(base64);
        textarea.setAttribute('readonly', '');
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        return document.execCommand('copy');
      } catch (_) {
        return false;
      } finally {
        textarea.remove();
      }
    },

    /// 查找栏显隐同步：查找栏打开时按钮不可见且不接收点击。
    setDocumentCopyButtonHidden(isHidden) {
      const btn = document.getElementById('mr-document-copy-btn');
      if (!btn) return;
      if (isHidden) {
        btn.classList.add('mr-document-copy-btn-hidden');
      } else {
        btn.classList.remove('mr-document-copy-btn-hidden');
      }
    },

    /// 运行时语言变化时更新按钮的 title 与 aria-label，不整页重新加载。
    setDocumentCopyButtonLabels(normal, copied) {
      const btn = document.getElementById('mr-document-copy-btn');
      if (!btn) return;
      const preview = document.querySelector('.markdown-preview');
      if (normal) {
        btn.dataset.normalTitle = normal;
        if (preview) preview.dataset.documentCopyTitle = normal;
      }
      if (copied) {
        btn.dataset.copiedTitle = copied;
        if (preview) preview.dataset.documentCopiedTitle = copied;
      }
      // 当前处于成功态时显示 copied 标签，否则显示 normal 标签。
      const isCopied = btn.classList.contains('mr-document-copy-btn-copied');
      const title = isCopied ? btn.dataset.copiedTitle : btn.dataset.normalTitle;
      btn.title = title;
      btn.setAttribute('aria-label', title);
    },

    highlightSearch(query, caseSensitive, wholeWord, currentIndex) {
      MR.clearSearchHighlight();
      if (!query) return 0;

      const content = document.getElementById('mr-content');
      if (!content) return 0;

      const flags = caseSensitive ? 'g' : 'gi';
      let pattern = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      if (wholeWord) pattern = '\\b' + pattern + '\\b';

      let regex;
      try {
        regex = new RegExp(pattern, flags);
      } catch (e) {
        return 0;
      }

      const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, null);
      const textNodes = [];
      while (walker.nextNode()) {
        textNodes.push(walker.currentNode);
      }

      const allMatches = [];

      textNodes.forEach(node => {
        const text = node.textContent;
        let match;
        while ((match = regex.exec(text)) !== null) {
          allMatches.push({
            node: node,
            index: match.index,
            length: match[0].length
          });
        }
      });

      // Sort by document position in REVERSE order for safe insertion.
      // Processing from end to start prevents surroundContents from
      // splitting text nodes and invalidating later match offsets.
      const sortedAllMatches = allMatches.slice().sort((a, b) => {
        const cmp = a.node.compareDocumentPosition(b.node);
        if (cmp & Node.DOCUMENT_POSITION_FOLLOWING) return 1;  // b comes first → process b before a
        if (cmp & Node.DOCUMENT_POSITION_PRECEDING) return -1; // a comes first → process a before b
        return b.index - a.index; // same node: higher index first
      });

      // Collect mark elements in document order for indexing
      const markElements = [];

      // Use Range API to wrap matches in <mark> elements
      for (const m of sortedAllMatches) {
        const range = document.createRange();
        try {
          range.setStart(m.node, m.index);
          range.setEnd(m.node, m.index + m.length);
        } catch (e) {
          continue;
        }

        const mark = document.createElement('mark');
        mark.className = 'mr-search-highlight';

        try {
          range.surroundContents(mark);
          markElements.unshift(mark); // prepend to maintain document order
        } catch (e) {
          // surroundContents fails when range crosses element boundaries — skip
          continue;
        }
      }

      // Assign sequential indices in document order
      markElements.forEach((mark, i) => {
        mark.dataset.searchIndex = i;
      });
      MR._searchHighlights = markElements;

      const matchCount = markElements.length;

      // Highlight current match
      if (currentIndex >= 0 && currentIndex < matchCount) {
        const currentMark = content.querySelector(`mark[data-search-index="${currentIndex}"]`);
        if (currentMark) {
          currentMark.classList.add('mr-search-current');
          currentMark.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      }

      return matchCount;
    },

    setSearchCurrent(currentIndex) {
      const content = document.getElementById('mr-content');
      if (!content) return;
      const prev = content.querySelector('.mr-search-current');
      if (prev) prev.classList.remove('mr-search-current');
      if (currentIndex >= 0) {
        const mark = content.querySelector(`mark[data-search-index="${currentIndex}"]`);
        if (mark) {
          mark.classList.add('mr-search-current');
          mark.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      }
    },

    clearSearchHighlight() {
      for (const mark of MR._searchHighlights) {
        const parent = mark.parentNode;
        if (parent) {
          while (mark.firstChild) {
            parent.insertBefore(mark.firstChild, mark);
          }
          parent.removeChild(mark);
          parent.normalize();
        }
      }
      MR._searchHighlights = [];
    },

    init() {
      MR.renderMermaid();
      MR.renderPlantUML();
      MR.renderKaTeX();
      MR.renderAdmonitions();
      MR.addCopyButtons();
      MR.addDocumentCopyButton();
      if (typeof Prism !== 'undefined') {
        Prism.highlightAll();
      }
    }
    ,
    /// 采集当前视口顶部的源码滚动锚点（小数源码位置 + 全文进度兜底）。
    /// 仅供单栏模式切换使用，不修改 MR.getTopVisibleLine / MR.scrollToLine。
    captureSourceScrollAnchor() {
      var scrollTop = window.scrollY || document.documentElement.scrollTop || 0;
      var blocks = [];
      var els = document.querySelectorAll('[data-source-start][data-source-end]');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        var start = parseInt(el.getAttribute('data-source-start'), 10);
        var end = parseInt(el.getAttribute('data-source-end'), 10);
        if (isNaN(start) || isNaN(end) || end < start) continue;
        var rect = el.getBoundingClientRect();
        var top = rect.top + scrollTop;
        var bottom = rect.bottom + scrollTop;
        var height = bottom - top;
        if (height <= 0) continue;
        blocks.push({ start: start, end: end, top: top, bottom: bottom, height: height });
      }
      if (blocks.length === 0) {
        var docHeight = document.documentElement.scrollHeight - window.innerHeight;
        var progress = docHeight > 0 ? scrollTop / docHeight : 0;
        return { sourcePosition: 1.0, documentProgress: Math.max(0, Math.min(1, progress)) };
      }
      blocks.sort(function (a, b) { return a.top - b.top; });
      var bestBlock = null;
      for (var j = 0; j < blocks.length; j++) {
        if (blocks[j].top <= scrollTop && blocks[j].bottom >= scrollTop) {
          if (bestBlock === null || blocks[j].height < bestBlock.height) {
            bestBlock = blocks[j];
          }
        }
      }
      if (bestBlock) {
        var progressInBlock = (scrollTop - bestBlock.top) / bestBlock.height;
        var sourcePosition = bestBlock.start + progressInBlock * (bestBlock.end + 1 - bestBlock.start);
        var docHeight = document.documentElement.scrollHeight - window.innerHeight;
        var docProgress = docHeight > 0 ? scrollTop / docHeight : 0;
        return { sourcePosition: sourcePosition, documentProgress: Math.max(0, Math.min(1, docProgress)) };
      }
      if (scrollTop < blocks[0].top) {
        var docHeight = document.documentElement.scrollHeight - window.innerHeight;
        var docProgress = docHeight > 0 ? scrollTop / docHeight : 0;
        return { sourcePosition: blocks[0].start, documentProgress: Math.max(0, Math.min(1, docProgress)) };
      }
      var last = blocks[blocks.length - 1];
      var docHeight = document.documentElement.scrollHeight - window.innerHeight;
      var docProgress = docHeight > 0 ? scrollTop / docHeight : 0;
      return { sourcePosition: last.end, documentProgress: Math.max(0, Math.min(1, docProgress)) };
    }
    ,
    /// 根据小数源码位置（或全文进度兜底）滚动到对应位置。
    /// 仅供单栏模式切换使用，不修改 MR.scrollToLine。
    /// 在至少一个 requestAnimationFrame 后返回 true，供 Swift 侧当作'已落位'回执。
    async scrollToSourceScrollAnchor(sourcePosition, documentProgress) {
      try {
        var blocks = [];
        var els = document.querySelectorAll('[data-source-start][data-source-end]');
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          var start = parseInt(el.getAttribute('data-source-start'), 10);
          var end = parseInt(el.getAttribute('data-source-end'), 10);
          if (isNaN(start) || isNaN(end) || end < start) continue;
          var rect = el.getBoundingClientRect();
          var top = rect.top + window.scrollY;
          var bottom = rect.bottom + window.scrollY;
          var height = bottom - top;
          if (height <= 0) continue;
          blocks.push({ start: start, end: end, top: top, bottom: bottom, height: height });
        }
        var targetY = null;
        if (blocks.length > 0 && typeof sourcePosition === 'number' && sourcePosition >= 1) {
          blocks.sort(function (a, b) { return a.top - b.top; });
          var bestBlock = null;
          for (var j = 0; j < blocks.length; j++) {
            if (blocks[j].start <= sourcePosition && blocks[j].end + 1 >= sourcePosition) {
              if (bestBlock === null || blocks[j].height < bestBlock.height) {
                bestBlock = blocks[j];
              }
            }
          }
          if (bestBlock) {
            var progressInBlock = (sourcePosition - bestBlock.start) / (bestBlock.end + 1 - bestBlock.start);
            targetY = bestBlock.top + progressInBlock * bestBlock.height;
          } else {
            for (var k = 0; k < blocks.length; k++) {
              if (blocks[k].start > sourcePosition) {
                if (k > 0) {
                  var prev = blocks[k - 1];
                  var ratio = (sourcePosition - (prev.end + 1)) / (blocks[k].start - (prev.end + 1));
                  targetY = prev.bottom + ratio * (blocks[k].top - prev.bottom);
                } else {
                  targetY = blocks[0].top;
                }
                break;
              }
            }
            if (targetY === null) {
              targetY = blocks[blocks.length - 1].bottom;
            }
          }
        }
        if (targetY === null && typeof documentProgress === 'number') {
          var docHeight = document.documentElement.scrollHeight - window.innerHeight;
          targetY = docHeight > 0 ? documentProgress * docHeight : 0;
        }
        if (targetY === null) {
          return false;
        }
        window.scrollTo({ top: targetY, behavior: 'auto' });
        await new Promise(function (resolve) { requestAnimationFrame(resolve); });
        return true;
      } catch (e) {
        return false;
      }
    }
  };

  window.MR = MR;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', MR.init);
  } else {
    MR.init();
  }
})();
