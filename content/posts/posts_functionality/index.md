+++
title = "Blog Posts Functionality"
description = "Exploire blog posting functionality"
date = 2024-01-20
colocated_path = "./"

[extra]
toc = true

[taxonomies]
tags = ["zola"]
categories = ["Technical"] 

+++

I am using Zola as a static site generator with theme. It provides an easy way to create posts in Markdown, requiring minimal configuration. Despite its simplicity, it is feature-rich and has no JavaScript/npm dependencies.

In this post, I am exploring various useful abilities of Markdown/HTML that can enhance blog posts.
<!-- more -->
<details>
    <summary>For example, hiding part of the content in a collapsible block:</summary>
    In the collapsed part, I can include extensive text without cluttering the page. This can be achieved using the following syntax:

```html
<details>
    <summary>Summary of the content</summary>
    Content itself
</details>
```
Syntax highlighting also works within these blocks.
</details>

I can include Markdown-style images like `![Image](img.jpg)`:

![Image](img.jpg)

Or link to an image/file like `[link to image](img.jpg)` : [link to image](img.jpg)


Additionally, I can use HTML tags for more control over the images:

```html
<img align="right"  src="img.jpg" width="128"> 
```
<img align="right"  src="img.jpg" width="128"> 


Lists are easy to create:
 - Point 1
 - Point 2
   - Subpoint
   - Subpoint 2
   - Subpoint 3
 - Point 3
   - Subpoint 3

## Headers or Chapter Titles Markdown Style

One interesting feature is the ability to inject scripts and create small HTML/JS-based dynamic content:

```html
<script>
  function showAlert() {
    alert('Hello, this is an alert!');
  }
</script>
<button onclick="showAlert()">Click me</button>
```

<script>
  function showAlert() {
    alert('Hello, this is an alert!');
  }
</script>
<button onclick="showAlert()">Click me</button>
