"======================================================================
|
|   Sandstone.SDFileStore class definition
|
 ======================================================================"

"======================================================================
|
| Copyright (c) 2008-2009 
| Ramon Leon <ramon.leon@allresnet.com>,
| 
|  Ported by:
|
| Sebastien Audier <sebastien.audier@gmail.com>
| Nicolas Petton   <petton.nicolas@gmail.com>
|
| Permission is hereby granted, free of charge, to any person obtaining
| a copy of this software and associated documentation files (the 
| 'Software'), to deal in the Software without restriction, including 
| without limitation the rights to use, copy, modify, merge, publish, 
| distribute, sublicense, and/or sell copies of the Software, and to 
| permit persons to whom the Software is furnished to do so, subject to 
| the following conditions:
|
| The above copyright notice and this permission notice shall be 
| included in all copies or substantial portions of the Software.
|
| THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, 
| EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
| MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
| IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY 
| CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
| TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
| SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.  
|
 ======================================================================"



SDCachedStore subclass: SDFileStore [
    | cache |
    
    <comment: 'I''m a store for persisting active records directly to disk via
    a SmartReference stream with a few extentions to make it non interactive.'''>
    <category: 'SandstoneDb-Store'>

    abortChanges: anObject [
	<category: 'actions'>
	| diskVersion |
	anObject critical: 
		[self removeCachedOfClass: anObject class from: anObject id.
		diskVersion := self cachedLoadOfClass: anObject class from: anObject id.
		diskVersion ifNil: 
			[self 
			    addCachedOfClass: anObject class
			    at: anObject id
			    put: anObject]
		    ifNotNil: [anObject becomeForward: diskVersion]]
    ]

    addCachedOfClass: aClass at: anId put: anObject [
	<category: 'actions'>
	(cache at: aClass) at: anId put: anObject
    ]

    commit: aBlock [
	<category: 'actions'>
	self shouldNotImplement
    ]

    ensureDown [
	<category: 'actions'>
	self initializeCache
    ]

    ensureForClass: aClass [
	<category: 'actions'>
	| dir |
	dir := (self dirForClass: aClass) createDirectory.
	0 to: 9 do: [:num | (dir directoryNamed: num asString) createDirectory].
	cache at: aClass
	    ifAbsentPut: 
		[SDConcurrentDictionary on: (Dictionary new: self defaultCacheSize)]
    ]

    loadClass: aClass atId: anId [
	<category: 'actions'>
	^
	[(ObjectDumper on: ((self dirForClass: aClass atId: anId) 
	    fullNameFor: anId , '.obj')) load] 
		on: Error
		do: [:err | SDLoadError signal: err messageText]
    ]

    recoverForClass: aClass [
	<category: 'actions'>
	self
	    finishPartialCommitsForClass: aClass;
	    deleteFailedCommitsForClass: aClass;
	    loadChangesForClass: aClass
    ]

    removeCachedOfClass: aClass from: anId [
	"calling delete multiple times shouldn't cause an error"

	<category: 'actions'>
	^(cache at: aClass) removeKey: anId ifAbsent: [nil]
    ]

    removeObject: anObject [
	<category: 'actions'>
	| dir |
	self removeCachedOfClass: anObject class from: anObject id.
	dir := self dirForClass: anObject class atId: anObject id.
	dir deleteFileNamed: anObject id , '.obj'.
	"kill any other versions or failed commits of this object"
	(dir fileNamesMatching: anObject id , '.*') 
	    do: [:e | dir deleteFileNamed: e]
    ]

    storeObject: origObject [
	"The basic idea here is to make a save as atomic as possible and no data
	 is corrupted, no partial writes, thus renaming files as atomic."

	<category: 'actions'>
	| currentVersion newVersion oldVersion dir anObject |
	(cache at: origObject class) at: origObject id put: origObject.
	anObject := origObject sandstoneDeepCopy sandstoneMarkReferences.
	dir := self dirForClass: anObject class atId: anObject id.
	currentVersion := dir fullNameFor: anObject id , '.obj'.
	newVersion := currentVersion , '.new'.
	oldVersion := currentVersion , '.old'.
	"just in case a previous commit failed and left junk around"
	dir deleteFileNamed: newVersion.
	"the flush ensures all data is actually written to disk before moving on"
	SmartRefStream newFileNamed: newVersion
	    do: 
		[:file | 
		file
		    sandstoneNextPutObjOnly: anObject;
		    flush].
	"just in case any junk was lying around that failed to die on last commit"
	dir deleteFileNamed: oldVersion.
	"the pre-commit, on first save there won't be a current version, and fileExists is
	 too expensive to check when it'll always be there except on first save"
	[dir sandstoneRename: currentVersion toBe: oldVersion] ifError: [].
	"now the actual commit"
	dir sandstoneRename: newVersion toBe: currentVersion.
	"clean up the junk (could fail if OS has lock on it for some reason)"
	dir deleteFileNamed: oldVersion
    ]

    updateObject: anObject [
	<category: 'actions'>
	self storeObject: anObject
    ]

    cachedLoadOfClass: aClass from: anId [
	<category: 'queries'>
	^(cache at: aClass) at: anId
	    ifAbsent: 
		[([self loadClass: aClass atId: anId] on: SDLoadError do: [nil]) 
		    ifNotNilDo: 
			[:it | 
			"seems I have to make sure to cache the object before I can resolve
			 it's references so any backreferences to it don't try and load from
			 disk again''"

			(cache at: aClass) at: anId put: it.
			it sandstoneResolveReferences]]
    ]

    dirForClass: aClass [
	"compute the path of superclasses all the way up to ActiveRecord, storing
	 subclass records as a subdirectory of the superclasses directory
	 allows ActiveRecord to deal with inheritance"

	<category: 'queries'>
	| parentClass lineage |
	aClass == SDActiveRecord 
	    ifTrue: 
		[Error 
		    signal: 'ActiveRecord itself is abstract, you must only  
 store subclasses'].
	lineage := OrderedCollection with: aClass.
	parentClass := aClass superclass.
	[parentClass == SDActiveRecord] whileFalse: 
		[lineage addFirst: parentClass.
		parentClass := parentClass superclass].
	^lineage inject: self defaultBaseDirectory
	    into: [:dir :each | dir name: each name]
    ]

    dirForClass: aClass atId: anId [
	"Grab the correct hashed subdirectory for this record"

	<category: 'queries'>
	^(self dirForClass: aClass) name: (self dirNameFor: anId)
    ]

    dirNameFor: anId [
	"Answers a string with one decimal digit corresponding to anId.  There is a bug
	 in this that does not ever hash to the directory 1, but because of existing datasets
	 this must remain, do not want to rehash my databases and it is no big deal"

	<category: 'queries'>
	self flag: #knownBug.
	^(anId inject: 0 into: [:sum :e | sum + e asInteger]) asReducedSumOfDigits 
	    printString
    ]

    familyForClass: aClass [
	"I'm returing raw cache dictionary here because this read only copy
	 doesn't need concurrency protection, just a naked dictionary''"

	<category: 'queries'>
	^aClass allSubclasses inject: (cache at: aClass) dictionary
	    into: [:sum :subclass | sum , (cache at: subclass) dictionary]
    ]

    defaultBaseDirectory [
	"you can override this if you want to force the db somewhere else"

	<category: 'defaults'>
	    ^File name: (File image asString, '.SandstoneDb')
    ]

    deleteFailedCommitsForClass: aClass [
	"all remaining .new files are failed commits, kill them"

	<category: 'crash recovery'>
	
	[(self dirForClass: aClass) 
	    allFilesMatching: '\.new$' 
	    do: [:each | each remove]] 
		on: Error
		do: [:err | Transcript show: err]
    ]

    finishPartialCommitsForClass: aClass [
	"find where .new exists but .obj doesn't, rename .obj.new to
	 .obj to finish commit'"

	<category: 'crash recovery'>
	
	[(self dirForClass: aClass)  
	    allFilesMatching: '\.new$' 
	    do: 
		[:each || objFile dir |
		objFile := File name: (each name copyReplacingAllRegex: '\.new' with: '').
		objFile exists ifFalse: [each renameTo: objFile name]]]
		on: Error
		do: 
		    [:err | 
		    Transcript
			show: err;
			cr]
    ]

    loadChangesForClass: aClass [
	<category: 'crash recovery'>
	| id obj |
	(self dirForClass: aClass) withSubdirectoriesDo: 
		[:dir | 
		[dir entries do: 
			[:each | 
			"there could be tens of thousands of entries, so using do with
			 a condition to avoid the copy a select would generate"
			each isDirectory 
			    ifFalse: 
				[id := each name copyUpTo: $..
				obj := (cache at: aClass) at: id ifAbsent: [nil].
				obj ifNil: [self cachedLoadOfClass: aClass from: id]
				    ifNotNil: [obj abortChanges]]]] 
			on: Error
			do: 
			    [:err | 
			    Transcript
				show: err;
				cr]]
    ]

    initialize [
	<category: 'initialization'>
	super initialize.
	self initializeCache
    ]

    initializeCache [
	<category: 'initialization'>
	cache := SDConcurrentDictionary 
		    on: (Dictionary new: self defaultCacheSize)
    ]
]
