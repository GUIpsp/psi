import std.conv;

import ast.expression, ast.declaration, ast.scope_;
import sym.dexpr;
// TODO: move this to semantic_, as a rewrite
DExpr readVariable(alias readLocal)(VarDecl var,Scope from){
	DExpr r=getContextFor!readLocal(var,from);
	if(r) return dField(r,var.getName);
	return readLocal(var.getName);
}
DExpr getContextFor(alias readLocal)(Declaration meaning,Scope sc)in{assert(meaning&&sc);}do{
	DExpr r=null;
	auto meaningScope=meaning.scope_;
	if(auto fd=cast(FunctionDef)meaning)
		meaningScope=fd.realScope;
	assert(sc&&sc.isNestedIn(meaningScope));
	for(auto csc=sc;csc !is meaningScope;){
		void add(string name){
			if(!r) r=readLocal(name);
			else r=dField(r,name);
			assert(!!cast(NestedScope)csc);
		}
		assert(cast(NestedScope)csc);
		if(!cast(NestedScope)(cast(NestedScope)csc).parent) break;
		if(auto fsc=cast(FunctionScope)csc){
			auto fd=fsc.getFunction();
			if(fd.isConstructor){
				if(meaning is fd.thisVar) break;
				add(fd.thisVar.getName);
			}else add(fd.contextName);
		}else if(cast(AggregateScope)csc) add(csc.getDatDecl().contextName);
		csc=(cast(NestedScope)csc).parent;
	}
	return r;
}
DExpr buildContextFor(alias readLocal)(FunctionDef fd,Scope sc)in{assert(fd&&sc);}do{ // template, forward references 'doIt'
	if(auto ctx=getContextFor!readLocal(fd,sc)) return ctx;
	DExpr[string] record;
	auto msc=fd.realScope;
	for(auto csc=msc;;csc=(cast(NestedScope)csc).parent){
		if(!cast(NestedScope)csc) break;
		auto captures=fd.captures;
		if(fd.isConstructor){
			import ast.semantic_: isInDataScope;
			auto dsc=isInDataScope(fd.scope_);
			assert(!!dsc);
			captures=dsc.decl.captures;
		}
		foreach(id;captures){ // TODO: this is a bit hacky
			void add(Declaration decl){
				if(!decl) return;
				if(decl.scope_ is csc){
					if(auto vd=cast(VarDecl)decl)
						if(auto var=readVariable!readLocal(vd,sc))
							record[vd.getName]=var;
				}
				if(auto fd2=cast(FunctionDef)decl)
					foreach(id2;fd2.captures)
						add(id2.meaning);
			}
			add(id.meaning);
		}
		if(!cast(NestedScope)(cast(NestedScope)csc).parent) break;
		if(auto dsc=cast(DataScope)csc){
			auto name=dsc.decl.contextName;
			record[name]=readLocal(name);
			break;
		}
		if(auto fsc=cast(FunctionScope)csc){
			auto cname=fsc.getFunction().contextName;
			record[cname]=readLocal(cname);
			break;
		}
	}
	return dRecord(record);
}
DExpr lookupMeaning(alias readLocal,alias readFunction)(Identifier id)in{assert(id && id.scope_,text(id," ",id.loc));}do{
	if(!id.meaning||!id.scope_||!id.meaning.scope_)
		return readLocal(id.name);
	if(auto vd=cast(VarDecl)id.meaning){
		DExpr r=getContextFor!readLocal(id.meaning,id.scope_);
		return r?dField(r,id.name):readLocal(id.name);
	}
	if(cast(FunctionDef)id.meaning) return readFunction(id);
	return null;
}
