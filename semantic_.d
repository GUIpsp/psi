import std.array,std.algorithm,std.range;
import std.format, std.conv;
import lexer,scope_,expression,type,declaration,error,util;

alias CommaExp=BinaryExp!(Tok!",");
alias AssignExp=BinaryExp!(Tok!"=");
alias AddExp=BinaryExp!(Tok!"+");
alias SubExp=BinaryExp!(Tok!"-");
alias MulExp=BinaryExp!(Tok!"*");
alias DivExp=BinaryExp!(Tok!"/");
alias PowExp=BinaryExp!(Tok!"^");
alias UMinusExp=UnaryExp!(Tok!"-");
alias UNegExp=UnaryExp!(Tok!"!");
alias LtExp=BinaryExp!(Tok!"<");
alias LeExp=BinaryExp!(Tok!"<=");
alias GtExp=BinaryExp!(Tok!">");
alias GeExp=BinaryExp!(Tok!">=");
alias EqExp=BinaryExp!(Tok!"==");
alias NeqExp=BinaryExp!(Tok!"!=");
alias OrExp=BinaryExp!(Tok!"||");
alias AndExp=BinaryExp!(Tok!"&&");
alias Exp=Expression;

void propErr(Expression e1,Expression e2){
	if(e1.sstate==SemState.error) e2.sstate=SemState.error;
}

Expression makeDeclaration(Expression expr,ref bool success,Scope sc){
	if(auto dat=cast(DatDecl)expr){
		if(dat.dtype) return expr;
		auto dsc=new DataScope(sc,dat);
		assert(!dat.dscope_);
		dat.dscope_=dsc;
		dat.dtype=new AggregateTy(dat);
		foreach(ref exp;dat.body_.s) exp=makeDeclaration(exp,success,dat.dscope_);
	}
	if(auto fd=cast(FunctionDef)expr){
		if(fd.fscope_) return fd;
		auto fsc=new FunctionScope(sc,fd);
		fd.fscope_=fsc;
		foreach(ref p;fd.params){
			if(!p.dtype){ // ℝ is the default parameter type
				p.dtype=New!Identifier("ℝ");
				p.dtype.loc=p.loc;
			}
			p=cast(Parameter)semantic(p,fsc);
			propErr(p,fd);
		}
		if(fd.rret){
			Type[] pty;
			foreach(p;fd.params){
				if(!p.vtype){
					assert(fd.sstate==SemState.error);
					return fd;
				}
				pty~=p.vtype;
			}
			fd.ret=typeSemantic(fd.rret,sc);
			if(!fd.ret) fd.sstate=SemState.error;
			else fd.ftype=funTy(tupleTy(pty),fd.ret);
		}
	}
	if(auto decl=cast(Declaration)expr){
		if(!decl.scope_) success&=sc.insert(decl);
		return decl;
	}
	if(auto ce=cast(CommaExp)expr){
		ce.e1=makeDeclaration(ce.e1,success,sc);
		ce.e2=makeDeclaration(ce.e2,success,sc);
		return ce;
	}
	if(auto be=cast(BinaryExp!(Tok!":="))expr){
		if(auto id=cast(Identifier)be.e1){
			auto vd=new VarDecl(id);
			vd.loc=id.loc;
			success&=sc.insert(vd);
			auto de=new SingleDefExp(vd,be);
			de.loc=be.loc;
			propErr(vd,de);
			return de;
		}else if(auto tpl=cast(TupleExp)be.e1){
			VarDecl[] vds;
			foreach(exp;tpl.e){
				auto id=cast(Identifier)exp;
				vds~=new VarDecl(id);
				vds[$-1].loc=id.loc;
				success&=sc.insert(vds[$-1]);
			}
			auto de=new MultiDefExp(vds,be);
			de.loc=be.loc;
			foreach(vd;vds) propErr(vd,de);
			return de;
		}else{
			sc.error("left hand side definition must be identifier or tuple of identifiers",expr.loc);
			success=false;
		}
		success&=expr.sstate==SemState.completed;
	}
	if(auto tae=cast(TypeAnnotationExp)expr){
		if(auto id=cast(Identifier)tae.e){
			auto vd=new VarDecl(id);
			vd.dtype=tae.t;
			vd.loc=id.loc;
			success&=sc.insert(vd);
			return vd;
		}
	}
	sc.error("not a declaration: '"~expr.toString()~"' ",expr.loc);
	expr.sstate=SemState.error;
	success=false;
	return expr;
}

Expression[] semantic(Expression[] exprs,Scope sc){
	bool success=true;
	foreach(ref expr;exprs) expr=makeDeclaration(expr,success,sc);
	foreach(ref expr;exprs){
		expr=semantic(expr,sc);
		success&=expr.sstate==SemState.completed;
	}
	return exprs;
}

bool isBuiltIn(Identifier id){
	if(!id) return false;
	switch(id.name){
	case "array":
	case "readCSV":
	case "CosUnifDist":
	case "Rayleigh","Bernoulli","Exp","Exponential","StudentT":
	case "Gauss","Pareto","Uniform","UniformInt","Beta","Gamma","Laplace","Weibull":
	case "TruncatedGauss":
	case "FromMarginal","SampleFrom": 
	case "Expectation":
	case "Categorical":
		return true;
	default: return false;
	}
}
Expression builtIn(Identifier id){
	Type t=null;
	switch(id.name){
	case "array": t=funTy(tupleTy([ℝ]),arrayTy(ℝ)); break;
	case "readCSV": t=funTy(tupleTy([stringTy]),arrayTy(ℝ)); break;
	case "CosUnifDist": t=funTy(unit,ℝ); break; // TDOO: remove
	case "Rayleigh","Bernoulli","Exp","Exponential","StudentT": t=funTy(tupleTy([ℝ]),ℝ); break;
	case "Gauss","Pareto","Uniform","UniformInt","Beta","Gamma","Laplace","Weibull":
		t=funTy(tupleTy([ℝ,ℝ]),ℝ); break;
	case "TruncatedGauss":
		t=funTy(tupleTy([ℝ,ℝ,ℝ,ℝ]),ℝ); break;
	case "FromMarginal","SampleFrom": t=unit; break; // those are actually magic polymorphic functions
	case "Expectation": t=funTy(tupleTy([ℝ]),ℝ); break; // TODO: this should be polymorphic too
	case "Categorical": t=funTy(tupleTy([arrayTy(ℝ)]),ℝ); break;
	default: return null;
	}
	id.type=t;
	id.sstate=SemState.completed;
	return id;
}


Expression semantic(Expression expr,Scope sc){
	alias Bool=ℝ; // TODO: maybe add 𝟚 as specific boolean type?
	if(expr.sstate==SemState.completed||expr.sstate==SemState.error) return expr;
	if(expr.sstate==SemState.started){
		sc.error("cyclic dependency",expr.loc);
		expr.sstate=SemState.error;
		return expr;
	}
	assert(expr.sstate==SemState.initial);
	expr.sstate=SemState.started;
	scope(exit){
		if(expr.sstate!=SemState.error){
			assert(!!expr.type,text(expr));
			expr.sstate=SemState.completed;
		}
	}
	if(auto cd=cast(CompoundDecl)expr){
		auto asc=new AggregateScope(sc);
		cd.ascope_=asc;
		foreach(e;cd.s) if(auto decl=cast(Declaration)e) if(!decl.scope_) asc.insert(decl);
		foreach(ref e;cd.s){
			e=semantic(e,asc);
			propErr(expr,cd);
		}
		cd.type=unit;
		return cd;
	}
	if(auto ce=cast(CompoundExp)expr){
		auto blsc=new BlockScope(sc);
		ce.blscope_=blsc;
		foreach(ref e;ce.s){
			if(auto ite=cast(IteExp)e){
				ite.cond=semantic(ite.cond,blsc);
				ite.then=cast(CompoundExp)semantic(ite.then,blsc);
				if(ite.othw) ite.othw=cast(CompoundExp)semantic(ite.othw,blsc);
				if(ite.cond.sstate==SemState.completed && ite.cond.type!is Bool){
					sc.error(format("cannot obtain truth value for type '%s'",ite.cond.type),ite.cond.loc);
					ite.sstate=SemState.error;
				}
				propErr(ite.cond,ite);
				propErr(ite.then,ite);
				if(ite.othw) propErr(ite.othw,ite);
				ite.type=unit;
				e=ite;
			}else e=semantic(e,blsc);
			propErr(e,ce);
		}
		ce.type=unit;
		return ce;
	}
	if(auto fd=cast(FunctionDef)expr){
		bool success=true;
		if(!fd.scope_) makeDeclaration(fd,success,sc);
		auto fsc=fd.fscope_;
		assert(!!fsc);
		auto bdy=cast(CompoundExp)semantic(fd.body_,fsc);
		assert(!!bdy);
		fd.body_=bdy;
		fd.type=unit;
		propErr(bdy,fd);
		Type[] pty;
		foreach(p;fd.params){
			if(!p.vtype){
				assert(fd.sstate==SemState.error);
				return fd;
			}
			pty~=p.vtype;
		}
		if(fd.ret&&!fd.ftype) fd.ftype=funTy(tupleTy(pty),fd.ret);
		return fd;
	}
	if(auto ret=cast(ReturnExp)expr){ // TODO: enforce presence, check constraints/allow at arbitrary locations in analysis
		auto fd=sc.getFunction();
		if(!fd){
			sc.error("return statement must be within function",ret.loc);
			ret.sstate=SemState.error;
			return ret;
		}
		ret.e=semantic(ret.e,sc);
		propErr(ret.e,ret);
		if(ret.sstate==SemState.error)
			return ret;
		if(!fd.rret) fd.ret=ret.e.type;
		if(!compatible(fd.ret,ret.e.type)){
			sc.error(format("'%s' is incompatible with return type '%s'",ret.e.type,fd.ret),ret.e.loc);
			ret.sstate=SemState.error;
			return ret;
		}
		ret.type=unit;
		return ret;
	}
	if(auto ce=cast(CallExp)expr){
		ce.e=semantic(ce.e,sc);
		propErr(ce.e,ce);
		foreach(ref e;ce.args){
			e=semantic(e,sc);
			propErr(e,ce);
		}
		if(ce.sstate==SemState.error)
			return ce;
		auto fun=ce.e;
		if(auto ft=cast(FunTy)fun.type){
			Type[] aty;
			foreach(a;ce.args){
				if(!a.type){
					assert(ce.sstate==SemState.error);
					return ce;
				}
				aty~=a.type;
			}
			auto atys=tupleTy(aty);
			if(!compatible(ft.dom,atys)){
				sc.error(format("expected argument types '%s', but '%s' was provided",ft.dom,atys),ce.loc);
				ce.sstate=SemState.error;
			}else{
				ce.type=ft.cod;
			}
		}else if(isBuiltIn(cast(Identifier)ce.e)){
			auto id=cast(Identifier)ce.e;
			switch(id.name){
			case "FromMarginal": 
				Type[] aty;
				foreach(a;ce.args){
					if(!a.type){
						assert(ce.sstate==SemState.error);
						return ce;
					}
					aty~=a.type;
				}
				ce.type=aty.length==1?aty[0]:tupleTy(aty); // TODO: this special casing is not very nice
				break;
			case "SampleFrom":
				return handleSampleFrom(ce,sc);
			default: assert(0,text("TODO: ",id.name));
			}
		}else{
			sc.error(format("cannot call expression of type '%s'",fun.type),ce.loc);
			ce.sstate=SemState.error;
		}
		return ce;
	}
	if(auto dat=cast(DatDecl)expr){
		bool success=true;
		if(!dat.dscope_) makeDeclaration(dat,success,sc);
		auto bdy=cast(CompoundDecl)semantic(dat.body_,dat.dscope_);
		assert(!!bdy);
		dat.body_=bdy;
		dat.type=unit;
		return dat;
	}
	if(auto vd=cast(VarDecl)expr){
		bool success=true;
		if(!vd.scope_) makeDeclaration(vd,success,sc);
		vd.type=unit;
		assert(vd.dtype,text(vd));
		vd.vtype=typeSemantic(vd.dtype,sc);
		if(!vd.vtype) vd.sstate=SemState.error;
		return vd;
	}
	if(auto be=cast(BinaryExp!(Tok!":="))expr){
		bool success=true;
		auto de=cast(DefExp)makeDeclaration(be,success,sc);
		assert(!!de);
		assert(success && de.init is be || de.sstate==SemState.error);
		be.e2=semantic(be.e2,sc);
		if(be.e2.sstate==SemState.completed){
			if(auto tpl=cast(TupleExp)be.e1){
				if(auto tt=cast(TupleTy)be.e2.type){
					if(tpl.length!=tt.types.length){
						sc.error(text("inconsistent number of tuple entries for definition: ",tpl.length," vs. ",tt.types.length),de.loc);
						de.setError();
					}
				}else{
					sc.error(format("cannot unpack type '%s' as a tuple",be.e2.type),de.loc);
					de.setError();
				}
			}
			de.setType(be.e2.type);
			de.type=unit;
		}else de.setError();
		return expr=de;
	}
	if(auto ae=cast(AssignExp)expr){
		ae.type=unit;
		ae.e1=semantic(ae.e1,sc);
		ae.e2=semantic(ae.e2,sc);
		propErr(ae.e1,ae);
		propErr(ae.e2,ae);
		if(ae.sstate==SemState.error)
			return ae;
		void checkLhs(Expression lhs){
			if(auto id=cast(Identifier)lhs){
				if(!cast(VarDecl)id.meaning){
					sc.error("can only assign to variables",expr.loc);
					ae.sstate=SemState.error;
				}
			}else if(auto tpl=cast(TupleExp)lhs){
				foreach(ref exp;tpl.e){
					auto id=cast(Identifier)exp;
					if(!id) goto LbadAssgnmLhs;
					if(!cast(VarDecl)id.meaning){
						sc.error("can only assign to variables",id.loc);
						ae.sstate=SemState.error;
						break;
					}
				}
			}else if(auto idx=cast(IndexExp)lhs){
				checkLhs(idx.e);
			}else{
			LbadAssgnmLhs:
				sc.error(format("cannot assign to '%s'",lhs),ae.e1.loc);
				ae.sstate=SemState.error;
			}
		}
		checkLhs(ae.e1);
		if(ae.sstate!=SemState.error&&!compatible(ae.e1.type,ae.e2.type)){
			if(auto id=cast(Identifier)ae.e1){
				sc.error(format("cannot assign '%s' to variable '%s' of type '%s'",ae.e2.type,id,id.type),ae.loc);
				assert(!!id.meaning);
				sc.note("declared here",id.meaning.loc);
			}else sc.error(format("cannot assign '%s' to '%s'",ae.e2.type,ae.e1.type),ae.loc);
			ae.sstate=SemState.error;
		}
		return ae;
	}
	if(auto id=cast(Identifier)expr){
		if(auto r=builtIn(id))
			return r;
		auto meaning=sc.lookup(id);
		if(!meaning){
			sc.error(format("undefined identifier '%s'",id), id.loc);
			id.sstate=SemState.error;
			return id;
		}
		id.meaning=meaning;
		propErr(meaning,id);
		id.type=typeForDecl(meaning);
		if(!id.type&&id.sstate!=SemState.error){
			sc.error("invalid forward reference",id.loc);
			id.sstate=SemState.error;
		}
		return id;
	}
	if(auto fe=cast(FieldExp)expr){
		fe.e=semantic(fe.e,sc);
		propErr(fe.e,fe);
		auto noMember(){
			sc.error(format("no member '%s' for type '%s",fe.f,fe.e.type),fe.loc);
			fe.sstate=SemState.error;
			return fe;
		}
		if(auto aggrty=cast(AggregateTy)fe.e.type){
			if(aggrty.decl&&aggrty.decl.dscope_){
				auto meaning=aggrty.decl.dscope_.lookupHere(fe.f);
				if(!meaning) return noMember();
				fe.f.meaning=meaning;
				fe.f.type=typeForDecl(meaning);
				fe.f.sstate=SemState.completed;
				fe.type=fe.f.type;
				if(!fe.type) fe.sstate=SemState.error;
				return fe;
			}else return noMember();
		}else if(auto at=cast(ArrayTy)fe.e.type){
			if(fe.f.name=="length"){
				fe.type=ℝ;
				fe.f.sstate=SemState.completed;
				return fe;
			}else return noMember();
		}else return noMember();
	}
	if(auto idx=cast(IndexExp)expr){
		idx.e=semantic(idx.e,sc);
		propErr(idx.e,idx);
		foreach(ref a;idx.a){
			a=semantic(a,sc);
			propErr(a,idx);
		}
		if(idx.sstate==SemState.error)
			return idx;
		if(auto at=cast(ArrayTy)idx.e.type){
			if(idx.a.length!=1){
				sc.error(format("only one index required to index type '%s'",at),idx.loc);
				idx.sstate=SemState.error;
			}else{
				if(!compatible(ℝ,idx.a[0].type)){
					sc.error(format("index should be number, not '%s'",idx.a[0].type),idx.loc);
					idx.sstate=SemState.error;
				}else{
					idx.type=at.next;
				}
			}
		}else if(auto tt=cast(TupleTy)idx.e.type){
			if(idx.a.length!=1){
				sc.error(format("only one index required to index type '%s'",tt),idx.loc);
				idx.sstate=SemState.error;
			}else{
				auto lit=cast(LiteralExp)idx.a[0];
				if(!lit||lit.lit.type!=Tok!"0"){
					sc.error(format("index for type '%s' should be integer constant",tt),idx.loc); // TODO: allow dynamic indexing if known to be safe?
					idx.sstate=SemState.error;
				}else{
					auto c=ℕ(lit.lit.str);
					if(c>=tt.types.length){
						sc.error(format("index for type '%s' is out of bounds [0..%s)",tt,tt.types.length),idx.loc);
						idx.sstate=SemState.error;
					}else{
						idx.type=tt.types[cast(size_t)c.toLong()];
					}
				}
			}
		}else{
			sc.error(format("type '%s' is not indexable",idx.e.type),idx.loc);
			idx.sstate=SemState.error;
		}
		return idx;
	}
	if(auto ce=cast(CommaExp)expr){
		ce.e1=semantic(ce.e1,sc);
		ce.e2=semantic(ce.e2,sc);
		ce.type=unit;
		return ce;
	}
	if(auto tpl=cast(TupleExp)expr){
		foreach(ref exp;tpl.e){
			exp=semantic(exp,sc);
			propErr(exp,tpl);
		}
		if(tpl.sstate!=SemState.error){
			tpl.type=tupleTy(tpl.e.map!(e=>e.type).array);
		}
		return tpl;
	}
	if(auto arr=cast(ArrayExp)expr){
		Type t; bool tok=true;
		Expression texp;
		foreach(ref exp;arr.e){
			exp=semantic(exp,sc);
			propErr(exp,arr);
			if(t){
				if(t !is exp.type && tok){
					sc.error(format("incompatible types '%s' and '%s' in array literal",t,exp.type),texp.loc);
					sc.note("incompatible entry",exp.loc);
					arr.sstate=SemState.error;
					tok=false;
				}
			}else{ t=exp.type; texp=exp; }
		}
		if(arr.e.length){
			arr.type=arrayTy(arr.e[0].type);
		}else{
			sc.error("empty array literals unsupported",arr.loc); // TODO
			arr.sstate=SemState.error;
		}
		return arr;
	}
	if(auto tae=cast(TypeAnnotationExp)expr){
		tae.e=semantic(tae.e,sc);
		tae.type=typeSemantic(tae.t,sc);
		propErr(tae.e,tae);
		propErr(tae.t,tae);
		if(tae.sstate==SemState.error)
			return tae;
		if(tae.e.type !is tae.type){
			sc.error(format("type is '%s', not '%s'",tae.e.type,tae.type),tae.loc);
			tae.sstate=SemState.error;
		}
		return tae;
	}

	Expression handleUnary(string name,Expression e,ref Expression e1,Type t1,Type r){
		e1=semantic(e1,sc);
		propErr(e1,e);
		if(e.sstate==SemState.error)
			return e;
		if(e1.type is t1){
			e.type=r;
		}else{
			sc.error(format("incompatible type '%s' for %s",e1.type,name),r.loc);
			e.sstate=SemState.error;
		}
		return e;
	}
	
	Expression handleBinary(string name,Expression e,ref Expression e1,ref Expression e2,Type t1,Type t2,Type r){
		e1=semantic(e1,sc);
		e2=semantic(e2,sc);
		propErr(e1,e);
		propErr(e2,e);
		if(e.sstate==SemState.error)
			return e;
		if(e1.type is t1 && e2.type is t1){
			e.type=r;
		}else{
			sc.error(format("incompatible types '%s' and '%s' for %s",e1.type,e2.type,name),e.loc);
			e.sstate=SemState.error;
		}
		return e;
	}

	if(auto ae=cast(AddExp)expr) return handleBinary("addition",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(SubExp)expr) return handleBinary("subtraction",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(MulExp)expr) return handleBinary("multiplication",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(DivExp)expr) return handleBinary("division",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(PowExp)expr) return handleBinary("power",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(UMinusExp)expr) return handleUnary("minus",ae,ae.e,ℝ,ℝ);
	if(auto ae=cast(UNegExp)expr) return handleUnary("negation",ae,ae.e,Bool,Bool);
	if(auto ae=cast(AndExp)expr) return handleBinary("conjunction",ae,ae.e1,ae.e2,Bool,Bool,Bool);
	if(auto ae=cast(OrExp)expr) return handleBinary("disjunction",ae,ae.e1,ae.e2,Bool,Bool,Bool);
	if(auto ae=cast(LtExp)expr) return handleBinary("'<'",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ae=cast(LeExp)expr) return handleBinary("'≤'",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ae=cast(GtExp)expr) return handleBinary("'>'",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ae=cast(GeExp)expr) return handleBinary("'≥'",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ae=cast(EqExp)expr) return handleBinary("'='",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ae=cast(NeqExp)expr) return handleBinary("'≠'",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ite=cast(IteExp)expr){
		ite.cond=semantic(ite.cond,sc);
		if(ite.then.s.length!=1||ite.othw&&ite.othw.s.length!=1){
			sc.error("branches of 'if' expression must be single expressions;",ite.loc);
			ite.sstate=SemState.error;
			return ite;
		}
		ite.then.s[0]=semantic(ite.then.s[0],sc);
		if(!ite.othw){
			sc.error("missing else for if expression",ite.loc);
			ite.sstate=SemState.error;
			return ite;
		}
		ite.othw.s[0]=semantic(ite.othw.s[0],sc);
		propErr(ite.cond,ite);
		propErr(ite.then,ite);
		propErr(ite.othw,ite);
		if(ite.sstate==SemState.error)
			return ite;
		auto t1=ite.then.s[0].type;
		auto t2=ite.othw.s[0].type;
		if(t1 !is t2){
			sc.error(format("incompatible types '%s' and '%s' for branches of 'if' expression",t1,t2),ite.loc);
			ite.sstate=SemState.error;
		}
		ite.type=t1;
		return ite;
	}
	if(auto fe=cast(ForExp)expr){
		auto fesc=new ForExpScope(sc,fe);
		auto vd=new VarDecl(fe.var);
		vd.vtype=ℝ;
		vd.loc=fe.var.loc;
		if(!fesc.insert(vd))
			fe.sstate=SemState.error;
		fe.fescope_=fesc;
		fe.loopVar=vd;
		fe.left=semantic(fe.left,fesc);
		if(fe.left.sstate==SemState.completed && fe.left.type!is ℝ){
			sc.error(format("lower bound for loop variable should be a number, not '%s",fe.left.type),fe.left.loc);
			fe.sstate=SemState.error;
		}
		fe.right=semantic(fe.right,fesc);
		if(fe.right.sstate==SemState.completed && fe.right.type!is ℝ){
			sc.error(format("upper bound for loop variable should be a number, not '%s",fe.right.type),fe.right.loc);
			fe.sstate=SemState.error;
		}
		fe.bdy=cast(CompoundExp)semantic(fe.bdy,fesc);
		assert(!!fe.bdy);
		propErr(fe.left,fe);
		propErr(fe.right,fe);
		fe.type=unit;
		return fe;
	}
	if(auto re=cast(RepeatExp)expr){
		re.num=semantic(re.num,sc);
		if(re.num.sstate==SemState.completed && re.num.type!is ℝ){
			sc.error(format("number of iterations should be a number, not '%s",re.num.type),re.num.loc);
			re.sstate=SemState.error;
		}
		re.bdy=cast(CompoundExp)semantic(re.bdy,sc);
		propErr(re.num,re);
		propErr(re.bdy,re);
		re.type=unit;
		return re;
	}
	if(auto oe=cast(ObserveExp)expr){
		oe.e=semantic(oe.e,sc);
		if(oe.e.sstate==SemState.completed && oe.e.type!is Bool){
			sc.error(format("cannot obtain truth value for type '%s'",oe.e.type),oe.e.loc);
			oe.sstate=SemState.error;
		}
		propErr(oe.e,oe);
		oe.type=unit;
		return oe;
	}
	if(auto oe=cast(CObserveExp)expr){ // TODO: get rid of cobserve!
		oe.var=semantic(oe.var,sc);
		oe.val=semantic(oe.val,sc);
		propErr(oe.var,oe);
		propErr(oe.val,oe);
		if(oe.sstate==SemState.error)
			return oe;
		if(oe.var.type!is ℝ || oe.val.type !is ℝ){
			sc.error("both arguments to cobserve should be real numbers",oe.loc);
			oe.sstate=SemState.error;
		}
		oe.type=unit;
		return oe;
	}
	if(auto ae=cast(AssertExp)expr){
		ae.e=semantic(ae.e,sc);
		if(ae.e.sstate==SemState.completed && ae.e.type!is Bool){
			sc.error(format("cannot obtain truth value for type '%s'",ae.e.type),ae.e.loc);
			ae.sstate=SemState.error;
		}
		propErr(ae.e,ae);
		ae.type=unit;
		return ae;
	}
	if(auto lit=cast(LiteralExp)expr){
		switch(lit.lit.type){
		case Tok!"0":
			expr.type=ℝ;
			return expr;
		case Tok!"``":
			expr.type=stringTy;
			return expr;
		default: break; // TODO
		}
	}
	sc.error("unsupported "~typeid(expr).to!string,expr.loc);
	expr.sstate=SemState.error;
	return expr;
}

Type typeSemantic(Expression t,Scope sc)in{assert(!!t&&!!sc);}body{
	if(auto id=cast(Identifier)t){
		if(id.name=="R"||id.name=="ℝ") return ℝ;
		if(id.name=="1"||id.name=="𝟙") return unit;
		auto decl=sc.lookup(id);
		if(!decl){
			sc.error(format("undefined identifier '%s'",id),id.loc);
			return null;
		}
		if(auto dat=cast(DatDecl)decl){
			return dat.dtype;
		}else{
			sc.error(format("%s '%s' is not a data type declaration",decl.kind,decl.name),id.loc);
			sc.note("declared here",decl.loc);
			return null;
		}
	}
	if(auto pr=cast(BinaryExp!(Tok!"×"))t){
		// TODO: allow nested declarations
		auto t1=typeSemantic(pr.e1,sc);
		auto t2=typeSemantic(pr.e2,sc);
		if(!t1||!t2) return null;
		auto l=cast(TupleTy)t1,r=cast(TupleTy)t2;
		if(l && r && !pr.e1.brackets && !pr.e2.brackets)
			return tupleTy(l.types~r.types);
		if(l&&!pr.e1.brackets) return tupleTy(l.types~t2);
		if(r&&!pr.e2.brackets) return tupleTy(t1~r.types);
		return tupleTy([t1,t2]);
	}
	if(auto at=cast(IndexExp)t){
		auto next=typeSemantic(at.e,sc);
		if(!next) return null;
		assert(at.a==[]);
		return arrayTy(next);
	}
	sc.error("not a type",t.loc);
	return null;
 }

Type typeForDecl(Declaration decl){
	if(auto dat=cast(DatDecl)decl){
		assert(cast(AggregateTy)dat.dtype);
		return dat.dtype;
	}
	if(auto vd=cast(VarDecl)decl){
		return vd.vtype;
	}
	if(auto fd=cast(FunctionDef)decl){
		if(!fd.ftype&&fd.scope_) fd=cast(FunctionDef)semantic(fd,fd.scope_);
		assert(!!fd);
		return fd.ftype;
	}
	return unit; // TODO
}

bool compatible(Type lhs,Type rhs){
	return lhs is rhs;
}


import dexpr;
struct VarMapping{
	DVar orig;
	DVar tmp;
}
struct SampleFromInfo{
	bool error;
	VarMapping[] retVars;
	DVar[] paramVars;
	DExpr newDist;	
}

import distrib; // TODO: separate concerns properly, move the relevant parts back to analysis.d
SampleFromInfo analyzeSampleFrom(CallExp ce,ErrorHandler err,Distribution dist=null){ // TODO: support for non-real-valued distributions
	if(ce.args.length==0){
		err.error("expected arguments to SampleFrom",ce.loc);
		return SampleFromInfo(true);
	}
	auto literal=cast(LiteralExp)ce.args[0];
	if(!literal||literal.lit.type!=Tok!"``"){
		err.error("first argument to SampleFrom must be string literal",ce.args[0].loc);
		return SampleFromInfo(true);
	}
	VarMapping[] retVars;
	DVar[] paramVars;
	DExpr newDist;
	import hashtable;
	HSet!(string,(a,b)=>a==b,a=>typeid(string).getHash(&a)) names;
	try{
		import dparse;
		auto parser=DParser(literal.lit.str);
		parser.skipWhitespace();
		parser.expect('(');
		for(bool seen=false;parser.cur()!=')';){
			parser.skipWhitespace();
			if(parser.cur()==';'){
				seen=true;
				parser.next();
				continue;
			}
			auto orig=parser.parseDVar();
			if(orig.name in names){
				err.error(text("multiple variables of name '",orig.name,"'"),ce.args[0].loc);
				return SampleFromInfo(true);
			}
			if(!seen){
				auto tmp=dist?dist.getTmpVar("__tmp"~orig.name):null; // TODO: this is a hack
				retVars~=VarMapping(orig,tmp);
			}else paramVars~=orig;
			parser.skipWhitespace();
			if(!";)"[seen..$].canFind(parser.cur())) parser.expect(',');
		}
		parser.next();
		parser.skipWhitespace();
		if(parser.cur()=='⇒') parser.next();
		else{ parser.expect('='); parser.expect('>'); }
		parser.skipWhitespace();
		newDist=parser.parseDExpr();
	}catch(Exception e){
		err.error(e.msg,ce.args[0].loc);
		return SampleFromInfo(true);
	}
	if(dist){
		foreach(var;retVars){
			if(!newDist.hasFreeVar(var.orig)){
				err.error(text("pdf must depend on variable '",var.orig.name,"')"),ce.args[0].loc);
				return SampleFromInfo(true);
			}
			newDist=newDist.substitute(var.orig,var.tmp); // TODO: make sure capturing is impossible here
		}
	}
	if(ce.args.length!=1+paramVars.length){
		err.error(text("expected ",paramVars.length," additional arguments to SampleFrom"),ce.loc);
		return SampleFromInfo(true);
	}
	return SampleFromInfo(false,retVars,paramVars,newDist);
}

Expression handleSampleFrom(CallExp ce,Scope sc){
	auto info=analyzeSampleFrom(ce,sc.handler);
	if(info.error){
		ce.sstate=SemState.error;
	}else{
		 // TODO: this special casing is not very nice:
		ce.type=info.retVars.length==1?ℝ:tupleTy((cast(Type)ℝ).repeat(info.retVars.length).array);
	}
	return ce;
}
