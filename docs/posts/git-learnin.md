---
title: Git Learnin
date: 2019-01-02T11:37:50-05:00
lastmod: 2019-01-02T11:37:50-05:00
cover: "/images/Git-Logo-2Color.png"
draft: false
categories: ["DevOps"]
tags: ["git", "devops", "introduction"]
description:
---
# gitlearnin
More and more I'm working with non-dev resources that are now needing to learn Git. The following is a quick and dirty guide I threw together to share with people that could use a quick git primer. 

## Initial Setup
https://git-scm.com/downloads

Check the current settings
```
git config --global --list
```

**Note:** You can also use --local to see the settings for a given repository, or leave it off to see ALL settings relevant to the current repository (global and local)

```
git config --global user.name "Steve Griffith"
git config --global user.email "stgriffi@microsoft.com"
```

## Setting your default editor
Many activities you do in git may pop you into an editor (ex. commits, diffs, etc). Git will use your system default editor, but you may want to change this as follows:

```
#Ex. Using Nano for linux or WSL
git config --global core.editor nano
```

## Cloning and Existing Repo
```
git clone https://github.com/swgriffith/gitlearnin.git
```

Now you have a local working copy of the repository that you cloned. You can do whatever you want with this copy, but need to be mindful of what you do if you intend to push back to **origin**. 

## What is origin?
Origin is the default name for the remote repository you cloned from. You can see your origin using the following:

```
git remote -v
```
You can rename your origin as well:

```
#git remote rename <originalName> <newName>
git remote rename origin github
git remote -v
```

**Note:** This name will be used when you interact with the remote repository for pushes.

## Branches
Branches allow you to work on various changes locally at the same time without them overlapping. To switch between branches you use **checkout**. For example, if you have 2 hot fixes you need to apply you can create a branch for each and swap back and forth between them without any conflict, until you're ready to push them to your origin.

**Note:** On your first check-in a 'master' branch is created for you automatically. **General best practice is to avoid making changes directly in master**

You create a new branch as follows:
```
git branch griffithmods
git checkout griffithmods
# or

git checkout -b griffithmods
```

You can delete a branch as follows:
```
git branch -d griffithmods
```

## Making changes
Once you've cloned a repository, created a branch and checked it out, you're ready to work. Create a new file within the cloned folder named <yourlastname.txt> and in that file enter the text 'commit1'.

This file is now in your folder, but has not been added to the repository. You can see this by trying to commit your change.

```
git commit -m "commit1" .
On branch griffithmods
Untracked files:
	griffith.txt

nothing added to commit but untracked files present

```

In order to commit this new file we need to add it to the repo:

```
git add griffith.txt
```

We're now ready to commit our change to the current branch. Every commit requires a comment be added. You can do this either in line, or git will bring up your editor to enter your commit message.

**Note:** This will commit all staged files. If you want to commit a single file you can name that file at the end of the command (ex. git commit griffith.txt). 

```
git commit -m "Added new file griffith.txt"
# or 
git commit
```

## Pushing to your remote repository (i.e. GitHub or Azure DevOps)
You can push to any remote repository you have listed when you run the following:
```
git remote -v
```

In this case we want to push our branch with it's changes up to github, so we'll run the following and when prompted enter our github credentials. 

**Note 1:** We'll come back to the credentials discussion, but use login and password for now.
**Note 2:** If you're not a collaborator on a remote repository, you cannot push to it. You will get an error.

```
#git push <remotename> <branchname>
git push github griffithmods
```

Now go take a look at your remote repository (i.e. GitHub or Azure DevOps) and see if your new branch is available in the branches list.

## Credentials
Entering your UserID and password may be a bit tedious on every remote repository push. Fortunately there are a few options to solve this pain.

1. Use credential manager
2. Use an SSH Key pair for authentication and SSH cloning instead of HTTPS cloning


### Using Credential Manager
To use credential manager you can simpley enable credential cache from global config. This will limit the frequency with which you have to enter your user id and password.

```
git config --global credential.helper cache
```

NEED TO ADD MORE HERE ABOUT WINDOWS CREDENTIAL MANAGER

### Using an SSG Key Pair
By generating an SSH key pair by using a tool like ssh-keygen, you can share your public key with your remote (i.e. GitHub or Azure DevOps). This key pair can be generated with or without a passphrase, although with is recommended. If you pull via the SSH endpoint rather than via the HTTPS endpoint, when you push git will attempt to use your ssh key to authenticate with the remote. If you've added your public key then you'll be able to push without entering a user ID and Password.

Using ssh-keygen from Linux, Mac or Windows Subsystem for Linux should look like the following. Again, entering a passphrase is recommended.

```
ssh-keygen
Generating public/private rsa key pair.
Enter file in which to save the key (/home/steve/.ssh/id_rsa):
Enter passphrase (empty for no passphrase): 
Enter same passphrase again: 
Your identification has been saved in /home/steve/.ssh/id_rsa3.
Your public key has been saved in /home/steve/.ssh/id_rsa3.pub.
The key fingerprint is:
SHA256:ubvUzxiRQd9Sj076+ZUv23GD5Af0bvagTah4mf5dsZ0 steve@griffith
The key's randomart image is:
+---[RSA 2048]----+
|          .   .  |
|         . . o o |
|          . o.+ .|
|         . o.=.  |
|        S o .o.o |
|         o .oo+.*|
|        o oo.o=E=|
|       . o+* ===B|
|        +++.= +o=|
+----[SHA256]-----+
```

The above process will create a new folder under /home/<username>/.ssh which contains the following files:

* **id_rsa** - File containing your private key
* **id_rsa.pub** - File containing your public key
* **known_hosts** - File tracking connections you've made to various hosts and which ssh-key was used


Grab the full contents of the id_rsa.pub files either opening the file or using cat on linux.

```
cat ~/.ssh/id_rsa.pub
ssh-rsa AAAA<BUNCH OF TEXT I REMOVED>EYM2Xj steve@griffith
```

Got do your remote repository, and add the ssh key for your user.

1. GitHub - You can find this by clicking on your user profile and going to 'Settings -> SSH and PGP Keys'
2. Azure DevOps - You can find this by clicking on your user profile and going to 'Security -> SSH Public Keys'

In either case you'll want to come up with a name for your key that represents where you're using it from (ex. Azure Cloud Shell, Windows PC, etc)

Once saved, you can now use the SSH endpoint for git clone and ssh for pushing to git remotes without user ID and password.

## Merging and Rebasing
There are a lot of cases where you'll need to get changes from one branch incorporated into another. There are two main mechanisms for this and each have separate uses, pros and cons.

### Merge
When you have two branches (ex. feature and master) a merge will allow you to take the changes from one branch and add them to the other as a new commit. This is nice because it's non-destructive. All of your commits to this point are maintained and you're just getting a new commit that merges from one branch to another. On the other hand, if you're merging from a very active branch you'll need ot merge pretty frequently and may not like having all of those commits cluttering up your history.

The following will merge the differences from the master branch into the feature branch as a new commit.
```
git merge feature master
```

### Rebase
When you rebase a branch you effectively move your branch forward replaying all of the commits from the one branch onto another. So, for example, if you created a feature branch from master yesterday morning and did some work, and then ran a rebase, git would rewind your feature branch to the begining and replay all of you're commits on the latest version of master. This is a nice clean way to move forward, but you're effectively destroying and re-writing your history.

To do this you checkout the branch you want to update and run rebase as follows:
```
git checkout feature    #Checks out the feature branch
git rebase master       #Rebases your feature branch from master
```

### Demo
```
mkdir test
cd test
git init
echo "commit1" > newfile.txt
git add newfile.txt
git commit -m "added file" .

git log
commit a086cff2c5f347edd6deccf133f222a68c332509 (HEAD -> master)
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:34:38 2018 -0500

    added file
```

Now create a new branch, change a file and merge from master.

```
git checkout -b feature
echo "commit2">>newfile.txt
git commit -m "commit2" .

git log
commit 16e09e47aebba5b04c73b59e50d2f1bf7ec89d63 (HEAD -> feature)
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:39:14 2018 -0500

    commit2

commit a086cff2c5f347edd6deccf133f222a68c332509 (master)
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:34:38 2018 -0500

    added file

```

```
git checkout master
echo "commit 3" > newfile2.txt
git add newfile2.txt
git commit -m "added another file" .

git log
commit b3a6cf1b3c25c398bfea4bda4cefd8e93b048c29 (HEAD -> master)
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:48:14 2018 -0500

    added another file

commit a086cff2c5f347edd6deccf133f222a68c332509
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:34:38 2018 -0500

    added file
```


```
git checkout feature
git merge feature master

git log
commit 1e28400cb8a1bbd25947c59980b2698317280f7e (HEAD -> feature)
Merge: 16e09e4 b3a6cf1
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:49:39 2018 -0500

    Merge branch 'master' into feature

commit b3a6cf1b3c25c398bfea4bda4cefd8e93b048c29 (master)
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:48:14 2018 -0500

    added another file

commit 16e09e47aebba5b04c73b59e50d2f1bf7ec89d63
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:39:14 2018 -0500

    commit2

commit a086cff2c5f347edd6deccf133f222a68c332509
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:34:38 2018 -0500

    added file

```

Now lets back out the merge and use a rebase instead. Take a look at the commit log for each option and pay special attention to the commit id and timestamps. You can see that rebase blew away the history and re-executed every commit, where the merge actually shows all of the original commits as the occured.

**Note:** git reset allows you to rewind your commits back. Think rewinding a tape, and your last commit is where the tape head is sitting before the rewind. When I say HEAD~1 that means go back one commit from where the HEAD currently sits. --hard means that I dont care if commits are discarded. You can use soft if you might want to recover commits after moving back in the commit tree.

```
git reset --hard HEAD~1
git rebase master

git log
commit ac0707a52ef4886b211c9bec14a7dc117d4fb36b (HEAD -> feature)
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:39:14 2018 -0500

    commit2

commit b3a6cf1b3c25c398bfea4bda4cefd8e93b048c29 (master)
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:48:14 2018 -0500

    added another file

commit a086cff2c5f347edd6deccf133f222a68c332509
Author: Steve Griffith <stgriffi@microsoft.com>
Date:   Thu Dec 13 20:34:38 2018 -0500

    added file

```
